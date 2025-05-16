require "tempfile"

module Shopify
  class BatchCreateListingsJob < ApplicationJob
    include HTTParty
    queue_as :shopify

    POLL_INTERVAL = 5.seconds # How often to check bulk operation status
    MAX_RETRIES = 3
    BATCH_SIZE = 250 # Maximum number of images per bulk upload

    def perform(shop_id:, product_ids:, batch_index:, total_batches:)
      @shop = Shop.find(shop_id)
      @client = ShopifyAPI::Clients::Graphql::Admin.new(session: @shop.shopify_session)
      @rest_client = ShopifyAPI::Clients::Rest::Admin.new(session: @shop.shopify_session)
      @batch_index = batch_index
      @total_batches = total_batches
      @retries = 0

      Rails.logger.info "[ShopifyBatch] Starting batch #{batch_index + 1}/#{total_batches} with #{product_ids.size} products"

      process_batch(product_ids)
    end

    private

    def process_batch(product_ids)
      # Prepare products for bulk operation using ListingService
      products_data = prepare_products_data(product_ids)

      # Start bulk operation
      bulk_operation = create_bulk_operation(products_data)

      if bulk_operation
        monitor_then_process_bulk_operation(bulk_operation, product_ids)
      else
        handle_batch_failure("Failed to create bulk operation")
      end
    rescue => e
      Rails.logger.error "[ShopifyBatch] Unexpected error: #{e.class} - #{e.message}\n#{e.backtrace.first(10).join("\n")}"
      handle_batch_failure(e)
    end

    def prepare_products_data(product_ids)
      products_data = []
      product_ids.each do |id|
        product = KuralisProduct.find(id)
        next if product.shopify_product.present?

        # Use ListingService to prepare product data
        service = Shopify::ListingService.new(product)
        products_data << {
          synchronous: true,
          productSet: {
            title: product.title,
            descriptionHtml: service.build_item_description,
            tags: product.tags,
            files: service.prepare_product_images,
            productOptions: [
              {
                name: "Title",
                position: 1,
                values: [ { name: "Default Title" } ]
              }
            ],
            variants: [
              {
                optionValues: [ { optionName: "Title", name: "Default Title" } ],
                inventoryItem: {
                  tracked: true,
                  measurement: {
                    weight: { unit: "OUNCES", value: product.weight_oz.to_f }
                  }
                },
                inventoryQuantities: [
                  { locationId: @shop.default_location_id, name: "available", quantity: product.base_quantity }
                ],
                price: product.base_price
              }
            ]
          }
        }
      end
      products_data
    end

    def create_bulk_operation(products_data)
      # Convert products data to JSONL format
      jsonl_data = products_data.map(&:to_json).join("\n")

      # Create staged upload for the JSONL file
      staged_upload = create_staged_upload(jsonl_data)
      return nil unless staged_upload

      # Extract the path from the key parameter
      upload_path = staged_upload["parameters"].find { |p| p["name"] == "key" }&.dig("value")
      return nil unless upload_path

      mutation = <<~GQL
        mutation {
          bulkOperationRunMutation(
            mutation: """
              mutation createProduct($productSet: ProductSetInput!, $synchronous: Boolean!) {
                productSet(synchronous: $synchronous, input: $productSet) {
                  product {
                    id
                    handle
                    variants(first: 1) {
                      nodes {
                        title
                        price
                        inventoryQuantity
                        inventoryItem {
                          id
                        }
                      }
                    }
                  }
                  userErrors {
                    field
                    message
                  }
                }
              }
            """,
            stagedUploadPath: "#{upload_path}"
          ) {
            bulkOperation {
              id
              status
            }
            userErrors {
              field
              message
            }
          }
        }
      GQL

      response = @client.query(query: mutation)
      Rails.logger.info "[ShopifyBatch] Bulk operation response: #{response.body}"

      if response.body["data"]&.dig("bulkOperationRunMutation", "bulkOperation")
        response.body["data"]["bulkOperationRunMutation"]["bulkOperation"]
      else
        Rails.logger.error "[ShopifyBatch] Failed to create bulk operation: #{response.body["errors"].inspect}"
        nil
      end
    end

    def create_staged_upload(data, type = "bulk_operation")
      filename = type == "media_creation" ? "media_creation.jsonl" : "products.jsonl"

      mutation = <<~GQL
        mutation stagedUploadsCreate($input: [StagedUploadInput!]!) {
          stagedUploadsCreate(input: $input) {
            stagedTargets {
              url
              resourceUrl
              parameters {
                name
                value
              }
            }
            userErrors {
              field
              message
            }
          }
        }
      GQL

      variables = {
        input: [ {
          resource: "BULK_MUTATION_VARIABLES",
          filename: filename,
          mimeType: "text/jsonl",
          httpMethod: "POST"
        } ]
      }

      response = @client.query(
        query: mutation,
        variables: variables
      )

      staged_target = response.body["data"]["stagedUploadsCreate"]["stagedTargets"].first
      return nil unless staged_target

      # Upload the file
      success = upload_to_url(staged_target, data)
      success ? staged_target : nil
    end

    def monitor_then_process_bulk_operation(operation, product_ids)
      loop do
        status = check_bulk_operation_status(operation["id"])
        Rails.logger.info "[ShopifyBatch] Bulk operation status: #{status}"

        case status["status"]
        when "COMPLETED"
          Rails.logger.info "[ShopifyBatch] Bulk operation completed, processing results"
          if status["url"]
            # Download and process the JSONL file
            response = HTTParty.get(status["url"])
            if response.success?
              process_bulk_operation_results(response.body, product_ids)
            else
              Rails.logger.error "[ShopifyBatch] Failed to download bulk operation results: #{response.code}"
              handle_batch_failure("Failed to download bulk operation results")
            end
          else
            Rails.logger.error "[ShopifyBatch] No URL provided in completed bulk operation"
            handle_batch_failure("No URL provided in completed bulk operation")
          end
          break
        when "FAILED"
          Rails.logger.error "[ShopifyBatch] Bulk operation failed: #{status["errorCode"]}"
          handle_batch_failure("Bulk operation failed: #{status["errorCode"]}")
          break
        else
          sleep POLL_INTERVAL
        end
      end
    end

    def check_bulk_operation_status(operation_id)
      query = <<~GQL
        query {
          node(id: "#{operation_id}") {
            ... on BulkOperation {
              id
              status
              errorCode
              createdAt
              completedAt
              objectCount
              fileSize
              url
              partialDataUrl
            }
          }
        }
      GQL

      response = @client.query(query: query)
      response.body["data"]["node"]
    end

    def process_bulk_operation_results(jsonl_data, product_ids)
      Rails.logger.info "[ShopifyBatch] Processing bulk operation results"
      results = []
      products_with_images = []

      jsonl_data.each_line do |line|
        result = JSON.parse(line)
        Rails.logger.info "[ShopifyBatch] Processing result line: #{result}"

        if result["data"] && result["data"]["productSet"] && result["data"]["productSet"]["product"]
          product_data = result["data"]["productSet"]["product"]
          variant_data = product_data["variants"]["nodes"].first

          # Create ShopifyProduct record using the same logic as ListingService
          product = KuralisProduct.find(product_ids[results.size])

          product_id = product_data["id"].split("/").last
          handle = product_data["handle"]
          variant_id = variant_data["inventoryItem"]["id"].split("/").last

          shopify_product = product.create_shopify_product!(
            shop: @shop,
            shopify_product_id: product_id,
            shopify_variant_id: variant_id,
            handle: handle,
            title: product.title,
            description: product.description,
            price: product.base_price,
            quantity: product.base_quantity,
            inventory_location: product.location,
            tags: product.tags,
            sku: product.sku,
            status: "active",
            published: true
          )

          # Copy images from kuralis_product to shopify_product
          if product.images.attached?
            product.images.each do |image|
              image.blob.open do |tempfile|
                shopify_product.images.attach(
                  io: tempfile,
                  filename: image.filename.to_s,
                  content_type: image.content_type,
                  identify: false
                )
              end
            end
          end

          # Add to products needing image upload to Shopify
          if product.images.attached?
            products_with_images << {
              product: product,
              shopify_product: shopify_product,
              shopify_product_id: product_id
            }
          end

          results << OpenStruct.new(success?: true)
        else
          Rails.logger.error "[ShopifyBatch] Invalid result format: #{result}"
          results << OpenStruct.new(
            success?: false,
            errors: result["data"]&.dig("productSet", "userErrors") || result["errors"]
          )
        end
      end

      # Process images in bulk using GraphQL
      process_images_with_graphql(products_with_images) if products_with_images.any?

      successful = results.count(&:success?)
      failed = results.count { |r| !r.success? }

      NotificationService.create(
        shop: @shop,
        title: "Shopify Batch #{@batch_index + 1}/#{@total_batches} Complete",
        message: "Processed #{results.size} products: #{successful} successful, #{failed} failed.",
        category: "bulk_listing",
        status: failed > 0 ? "warning" : "success"
      )

      # Log any failures for investigation
      results.reject(&:success?).each do |result|
        Rails.logger.error "[ShopifyBatch] Product creation failed: #{result.errors.inspect}"
      end
    end

    def process_images_with_graphql(products_with_images)
      Rails.logger.info "[ShopifyBatch] Starting batch image upload for #{products_with_images.size} products"

      # Group products into batches of 10 for processing
      products_with_images.each_slice(10) do |product_batch|
        # Collect all images that need uploads
        image_uploads = []

        # Map of image ID to product/image data for post-upload processing
        image_mapping = {}

        # Prepare all staged upload inputs in a batch
        staged_upload_inputs = []

        product_batch.each do |product_data|
          product = product_data[:product]
          shopify_product_id = product_data[:shopify_product_id]

          product.images.each_with_index do |image, index|
            # Create a unique ID for tracking this image
            image_id = "#{shopify_product_id}_#{index}"

            # Store the relationship between image ID and product data
            image_mapping[image_id] = {
              product: product,
              image: image,
              shopify_product_id: shopify_product_id
            }

            # Add to the batch of staged upload inputs
            staged_upload_inputs << {
              resource: "PRODUCT_IMAGE",
              filename: image.filename.to_s,
              mimeType: image.content_type,
              httpMethod: "POST"
            }
          end
        end

        # Skip if no images to upload
        next if staged_upload_inputs.empty?

        begin
          # Create all staged uploads in a single API call
          Rails.logger.info "[ShopifyBatch] Creating #{staged_upload_inputs.size} staged uploads in one API call"
          staged_upload_result = @client.query(
            query: build_staged_upload_mutation,
            variables: {
              input: staged_upload_inputs
            }
          )
          Rails.logger.info "-------------------------------- "
          Rails.logger.info "[ShopifyBatch] Staged upload result: #{staged_upload_result.body}"
          Rails.logger.info "--------------------------------"
          if staged_upload_result.body["data"] && staged_upload_result.body["data"]["stagedUploadsCreate"]
            staged_targets = staged_upload_result.body["data"]["stagedUploadsCreate"]["stagedTargets"]

            # Process each staged target (should match the order of our inputs)
            staged_targets.each_with_index do |staged_target, index|
              # Get the image ID for this staged target
              image_id = image_mapping.keys[index]
              image_data = image_mapping[image_id]

              next unless image_data

              # Convert parameters array to hash
              upload_params = staged_target["parameters"].each_with_object({}) do |param, hash|
                hash[param["name"]] = param["value"]
              end

              # Upload the file to the staged URL
              image_data[:image].blob.open do |file|
                upload_response = HTTParty.post(
                  staged_target["url"],
                  multipart: true,
                  body: upload_params.merge("file" => file)
                )

                if upload_response.success?
                  # Store for media creation
                  image_uploads << {
                    product_id: image_data[:shopify_product_id],
                    resource_url: staged_target["resourceUrl"],
                    image_alt: image_data[:product].title
                  }
                else
                  Rails.logger.error "[ShopifyBatch] Failed to upload image to staged URL for product #{image_data[:shopify_product_id]}: #{upload_response.code} - #{upload_response.body}"
                end
              end
            end

            # Now create media for all successfully uploaded images using a bulk operation
            # if image_uploads.any?
            #   create_media_bulk_operation(image_uploads)
            # end
          else
            Rails.logger.error "[ShopifyBatch] Failed to create staged uploads: #{staged_upload_result.body["errors"]}"
          end
        rescue => e
          Rails.logger.error "[ShopifyBatch] Error during batch image upload: #{e.message}"
          Rails.logger.error e.backtrace.first(5).join("\n")
        end

        # Add a small delay between batches
        sleep(1)
      end
    end

    def create_media_bulk_operation(image_uploads)
      # Convert image uploads to JSONL for bulk operation
      jsonl_data = image_uploads.map do |upload|
        {
          productId: "gid://shopify/Product/#{upload[:product_id]}",
          media: {
            mediaContentType: "IMAGE",
            originalSource: upload[:resource_url],
            alt: upload[:image_alt]
          }
        }.to_json
      end.join("\n")

      # Create staged upload for the JSONL file
      staged_upload = create_staged_upload(jsonl_data, "media_creation")
      return unless staged_upload

      # Extract the path from the key parameter
      upload_path = staged_upload["parameters"].find { |p| p["name"] == "key" }&.dig("value")
      return unless upload_path

      Rails.logger.info "[ShopifyBatch] Starting bulk media creation operation"

      mutation = <<~GQL
        mutation {
          bulkOperationRunMutation(
            mutation: """
              mutation createProductMedia($productId: ID!, $media: CreateMediaInput!) {
                productCreateMedia(productId: $productId, media: [$media]) {
                  media {
                    ... on MediaImage {
                      id
                    }
                  }
                  mediaUserErrors {
                    field
                    message
                  }
                }
              }
            """,
            stagedUploadPath: "#{upload_path}"
          ) {
            bulkOperation {
              id
              status
            }
            userErrors {
              field
              message
            }
          }
        }
      GQL

      response = @client.query(query: mutation)
      Rails.logger.info "[ShopifyBatch] Bulk media creation response: #{response.body}"

      if response.body["data"]&.dig("bulkOperationRunMutation", "bulkOperation")
        operation = response.body["data"]["bulkOperationRunMutation"]["bulkOperation"]

        # Monitor the bulk operation
        monitor_media_bulk_operation(operation["id"])
      else
        Rails.logger.error "[ShopifyBatch] Failed to create bulk media operation: #{response.body["errors"].inspect}"
      end
    end

    def monitor_media_bulk_operation(operation_id)
      Rails.logger.info "[ShopifyBatch] Monitoring media bulk operation: #{operation_id}"

      loop do
        status = check_bulk_operation_status(operation_id)
        Rails.logger.info "[ShopifyBatch] Media bulk operation status: #{status}"

        case status["status"]
        when "COMPLETED"
          Rails.logger.info "[ShopifyBatch] Media bulk operation completed successfully"
          break
        when "FAILED"
          Rails.logger.error "[ShopifyBatch] Media bulk operation failed: #{status["errorCode"]}"
          break
        when "CANCELING", "CANCELED"
          Rails.logger.error "[ShopifyBatch] Media bulk operation was canceled"
          break
        else
          sleep POLL_INTERVAL
        end
      end
    end

    def build_staged_upload_mutation
      <<~GQL
        mutation stagedUploadsCreate($input: [StagedUploadInput!]!) {
          stagedUploadsCreate(input: $input) {
            stagedTargets {
              url
              resourceUrl
              parameters {
                name
                value
              }
            }
            userErrors {
              field
              message
            }
          }
        }
      GQL
    end

    def upload_to_url(staged_target, data)
      uri = URI.parse(staged_target["url"])

      # Prepare parameters from staged target
      params = staged_target["parameters"].each_with_object({}) do |param, hash|
        hash[param["name"]] = param["value"]
      end

      # Create a temporary file for the upload
      file = Tempfile.new([ "products", ".jsonl" ])
      begin
        file.write(data)
        file.rewind

        # Upload the file using HTTParty
        response = self.class.post(
          uri.to_s,
          multipart: true,
          body: params.merge(
            file: File.open(file.path)
          )
        )

        if response.success?
          true
        else
          Rails.logger.error "[ShopifyBatch] Failed to upload file: #{response.code} - #{response.body}"
          false
        end
      ensure
        file.close
        file.unlink
      end
    rescue => e
      Rails.logger.error "[ShopifyBatch] Error uploading file: #{e.message}"
      false
    end

    def handle_batch_failure(error)
      NotificationService.create(
        shop: @shop,
        title: "Shopify Batch #{@batch_index + 1} Failed",
        message: "Batch failed: #{error}. Please check logs for details.",
        category: "bulk_listing",
        status: "error"
      )
    end
  end
end
