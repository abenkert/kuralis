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
      @batch_index = batch_index
      @total_batches = total_batches
      @retries = 0

      Rails.logger.info "[ShopifyBatch] Starting batch #{batch_index + 1}/#{total_batches} with #{product_ids.size} products"

      process_batch(product_ids)
    end

    private

    def process_batch(product_ids)
      begin
        # Step 1: Gather all products and their images first
        Rails.logger.info "[ShopifyBatch] Preparing products and images for processing"
        products_data = []
        image_uploads = []

        product_ids.each do |id|
          product = KuralisProduct.find(id)
          next if product.shopify_product.present?

          # Prepare product data for later use
          product_data = {
            product: product,
            image_urls: []
          }

          # Add image data if images exist
          if product.images.attached?
            product.images.each do |image|
              image_uploads << {
                product_id: product.id,
                product_data: product_data,  # Reference to where URLs should be stored
                image: image,
                alt: product.title
              }
            end
          end

          products_data << product_data
        end

        # Step 2: Process all images in bulk if we have any
        if image_uploads.any?
          Rails.logger.info "[ShopifyBatch] Processing #{image_uploads.size} images for #{products_data.size} products"
          process_images_in_bulk(image_uploads)
        end

        # Step 3: Create products with prepared image URLs
        Rails.logger.info "[ShopifyBatch] Creating #{products_data.size} products with prepared image URLs"
        create_products_in_bulk(products_data)

      rescue => e
        Rails.logger.error "[ShopifyBatch] Unexpected error: #{e.class} - #{e.message}\n#{e.backtrace.first(10).join("\n")}"
        handle_batch_failure(e)
      end
    end

    def process_images_in_bulk(image_uploads)
      return if image_uploads.empty?

      # Step 1: Create all staged uploads in batches
      Rails.logger.info "[ShopifyBatch] Creating staged uploads for #{image_uploads.size} images"
      staged_uploads = []

      image_uploads.each_slice(10) do |batch|
        # Prepare inputs for the staged uploads
        inputs = batch.map do |upload|
          {
            resource: "IMAGE",
            filename: upload[:image].filename.to_s,
            mimeType: upload[:image].content_type,
            fileSize: upload[:image].byte_size.to_s,
            httpMethod: "POST"
          }
        end

        # Create staged uploads
        staged_upload_result = @client.query(
          query: build_staged_upload_mutation,
          variables: { input: inputs }
        )

        if staged_upload_result.body["data"] && staged_upload_result.body["data"]["stagedUploadsCreate"]
          # Match staged uploads with original image data
          targets = staged_upload_result.body["data"]["stagedUploadsCreate"]["stagedTargets"]
          batch.each_with_index do |upload, index|
            if targets[index]
              staged_uploads << {
                image_data: upload,
                staged_target: targets[index]
              }
            end
          end
        else
          Rails.logger.error "[ShopifyBatch] Failed to create staged uploads: #{staged_upload_result.body["errors"] || staged_upload_result.body["data"]["stagedUploadsCreate"]["userErrors"]}"
        end
      end

      # Step 2: Upload files to all staged URLs and map resource URLs to products
      Rails.logger.info "[ShopifyBatch] Uploading #{staged_uploads.size} images to staged URLs"

      staged_uploads.each do |upload_data|
        image_data = upload_data[:image_data]
        staged_target = upload_data[:staged_target]

        # Convert parameters array to hash
        params = staged_target["parameters"].each_with_object({}) do |param, hash|
          hash[param["name"]] = param["value"]
        end

        # Upload the image
        success = false
        image_data[:image].blob.open do |file|
          response = HTTParty.post(
            staged_target["url"],
            multipart: true,
            body: params.merge("file" => file)
          )

          if response.success?
            # Store the resource URL with the product data
            resource_url = staged_target["resourceUrl"]
            image_data[:product_data][:image_urls] << {
              resource_url: resource_url,
              alt: image_data[:alt]
            }
            success = true
            Rails.logger.info "[ShopifyBatch] Successfully uploaded image for product #{image_data[:product_id]}"
          else
            Rails.logger.error "[ShopifyBatch] Failed to upload image: #{response.code} - #{response.body}"
          end
        end

        unless success
          Rails.logger.error "[ShopifyBatch] Image upload failed for product #{image_data[:product_id]}"
        end
      end
    end

    def create_products_in_bulk(products_data)
      # Filter out products with no data
      products_data = products_data.select { |data| data[:product].present? }
      return if products_data.empty?

      # Prepare JSONL data for bulk operation
      jsonl_data = products_data.map do |data|
        product = data[:product]

        # Use ListingService to prepare product data
        service = Shopify::ListingService.new(product)
        product_input = {
          synchronous: true,
          productSet: {
            title: product.title,
            descriptionHtml: service.build_item_description,
            tags: product.tags,
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

        # Add files if we have any for this product
        if data[:image_urls].present?
          product_input[:productSet][:files] = data[:image_urls].map do |image_data|
            {
              originalSource: image_data[:resource_url],
              alt: image_data[:alt]
            }
          end
        end

        product_input.to_json
      end.join("\n")

      # Create staged upload for the JSONL file
      staged_upload = create_staged_upload(jsonl_data)
      unless staged_upload
        Rails.logger.error "[ShopifyBatch] Failed to create staged upload for product data"
        return handle_batch_failure("Failed to create staged upload for product data")
      end

      # Extract the path from the key parameter
      upload_path = staged_upload["parameters"].find { |p| p["name"] == "key" }&.dig("value")
      unless upload_path
        Rails.logger.error "[ShopifyBatch] Failed to extract upload path from staged upload"
        return handle_batch_failure("Failed to extract upload path from staged upload")
      end

      # Start bulk operation for product creation
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
      Rails.logger.info "[ShopifyBatch] Bulk product creation operation response: #{response.body}"

      if response.body["data"]&.dig("bulkOperationRunMutation", "bulkOperation")
        operation = response.body["data"]["bulkOperationRunMutation"]["bulkOperation"]

        # Wait for bulk operation to complete and process results
        monitor_then_process_bulk_operation(operation, products_data.map { |d| d[:product].id })
      else
        Rails.logger.error "[ShopifyBatch] Failed to create bulk product operation: #{response.body["errors"] || response.body["data"]["bulkOperationRunMutation"]["userErrors"]}"
        handle_batch_failure("Failed to create bulk product operation")
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

          results << OpenStruct.new(success?: true)
        else
          Rails.logger.error "[ShopifyBatch] Invalid result format: #{result}"
          results << OpenStruct.new(
            success?: false,
            errors: result["data"]&.dig("productSet", "userErrors") || result["errors"]
          )
        end
      end

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
