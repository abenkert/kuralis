require "tempfile"
require "net/http"

module Shopify
  class BatchCreateListingsJob < ApplicationJob
    include HTTParty
    queue_as :shopify

    POLL_INTERVAL = 5.seconds # How often to check bulk operation status
    MAX_RETRIES = 5
    RETRY_DELAY = 5.seconds
    SSL_MAX_RETRIES = 5  # More retries for SSL issues
    SSL_RETRY_DELAY = 10.seconds  # Longer delay between SSL retry attempts
    BATCH_SIZE = 250 # Maximum number of images per bulk upload

    # Bulk operation retry configuration
    BULK_OP_MAX_RETRIES = 12  # Up to 1 hour of retries (with exponential backoff)
    BULK_OP_INITIAL_RETRY_DELAY = 30.seconds
    BULK_OP_MAX_DELAY = 600.seconds  # Cap at 10 minutes

    # Redis keys for tracking overall progress
    REDIS_KEY_PREFIX = "shopify_bulk_import"

    attr_reader :job_run_id

    def perform(shop_id:, product_ids:, batch_index:, total_batches:)
      @shop = Shop.find(shop_id)
      @client = ShopifyAPI::Clients::Graphql::Admin.new(session: @shop.shopify_session)
      @batch_index = batch_index
      @total_batches = total_batches
      @retries = 0

      # Generate a unique job run ID for this import session
      @job_run_id = generate_or_retrieve_job_run_id

      # Track batch start in Redis
      update_batch_status("started")

      Rails.logger.info "[ShopifyBatch] Starting batch #{batch_index + 1}/#{total_batches} with #{product_ids.size} products (Job Run ID: #{@job_run_id})"

      # Process the batch and track its completion
      process_batch(product_ids)
    end

    # Method to get progress information for this job
    def progress_info
      Shopify::BulkImportTracker.for_job(self)
    end

    private

    # Robust retry method that handles SSL connection errors
    def with_retries(max_retries: MAX_RETRIES, retry_delay: RETRY_DELAY, ssl_retry: false, operation: "API call")
      retries = 0
      ssl_retries = 0
      begin
        yield
      rescue OpenSSL::SSL::SSLError, Errno::ECONNRESET, EOFError, Net::ReadTimeout, Net::OpenTimeout => e
        ssl_retries += 1
        max = ssl_retry ? SSL_MAX_RETRIES : MAX_RETRIES
        delay = ssl_retry ? SSL_RETRY_DELAY : RETRY_DELAY

        if ssl_retries <= max
          Rails.logger.warn "[ShopifyBatch] SSL connection error during #{operation}: #{e.class} - #{e.message}. Retrying in #{delay} seconds (#{ssl_retries}/#{max})"
          sleep delay
          retry
        else
          Rails.logger.error "[ShopifyBatch] SSL connection error during #{operation} after #{ssl_retries} retries: #{e.class} - #{e.message}"
          raise
        end
      rescue => e
        retries += 1
        if retries <= max_retries
          Rails.logger.warn "[ShopifyBatch] Error during #{operation}: #{e.class} - #{e.message}. Retrying in #{retry_delay} seconds (#{retries}/#{max_retries})"
          sleep retry_delay
          retry
        else
          Rails.logger.error "[ShopifyBatch] Error during #{operation} after #{retries} retries: #{e.class} - #{e.message}"
          raise
        end
      end
    end

    def generate_or_retrieve_job_run_id
      # Try to get existing job run ID for this group of batches
      job_run_id = Rails.cache.read("#{REDIS_KEY_PREFIX}:current_job_run_id")

      unless job_run_id
        # Create a new job run ID if none exists
        job_run_id = SecureRandom.uuid
        Rails.cache.write("#{REDIS_KEY_PREFIX}:current_job_run_id", job_run_id, expires_in: 24.hours)

        # Initialize counters for this job run
        Rails.cache.write("#{REDIS_KEY_PREFIX}:#{job_run_id}:total_batches", @total_batches, expires_in: 24.hours)
        Rails.cache.write("#{REDIS_KEY_PREFIX}:#{job_run_id}:completed_batches", 0, expires_in: 24.hours)
        Rails.cache.write("#{REDIS_KEY_PREFIX}:#{job_run_id}:total_products", 0, expires_in: 24.hours)
        Rails.cache.write("#{REDIS_KEY_PREFIX}:#{job_run_id}:successful_products", 0, expires_in: 24.hours)
        Rails.cache.write("#{REDIS_KEY_PREFIX}:#{job_run_id}:failed_products", 0, expires_in: 24.hours)
      end

      job_run_id
    end

    def update_batch_status(status, successful_products = 0, failed_products = 0)
      case status
      when "started"
        # Nothing specific needs to be done, counters are initialized in generate_or_retrieve_job_run_id
      when "completed"
        # Increment completed batches
        Rails.cache.increment("#{REDIS_KEY_PREFIX}:#{@job_run_id}:completed_batches")

        # Update product counters
        Rails.cache.increment("#{REDIS_KEY_PREFIX}:#{@job_run_id}:total_products", successful_products + failed_products)
        Rails.cache.increment("#{REDIS_KEY_PREFIX}:#{@job_run_id}:successful_products", successful_products)
        Rails.cache.increment("#{REDIS_KEY_PREFIX}:#{@job_run_id}:failed_products", failed_products)

        # Check if this was the final batch
        completed_batches = Rails.cache.read("#{REDIS_KEY_PREFIX}:#{@job_run_id}:completed_batches").to_i
        total_batches = Rails.cache.read("#{REDIS_KEY_PREFIX}:#{@job_run_id}:total_batches").to_i

        if completed_batches >= total_batches
          send_final_notification
        end
      end
    end

    def send_final_notification
      # Get the final stats
      total_products = Rails.cache.read("#{REDIS_KEY_PREFIX}:#{@job_run_id}:total_products").to_i
      successful_products = Rails.cache.read("#{REDIS_KEY_PREFIX}:#{@job_run_id}:successful_products").to_i
      failed_products = Rails.cache.read("#{REDIS_KEY_PREFIX}:#{@job_run_id}:failed_products").to_i

      # Create notification
      NotificationService.create(
        shop: @shop,
        title: "Shopify Bulk Import Complete",
        message: "All batches completed. Total products processed: #{total_products}, " \
                 "Successfully imported: #{successful_products}, Failed: #{failed_products}.",
        category: "bulk_listing",
        status: failed_products > 0 ? "warning" : "success"
      )

      # Clean up Redis keys (but keep them around for a bit for debugging)
      Rails.cache.delete("#{REDIS_KEY_PREFIX}:current_job_run_id", expires_in: 1.hour)
    end

    def process_batch(product_ids)
      begin
        # Step 1: Gather all products and their images first
        Rails.logger.info "[ShopifyBatch] Preparing products and images for processing"
        products_data = []
        image_uploads = []
        failed_products = []

        product_ids.each do |id|
          begin
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
          rescue ActiveStorage::FileNotFoundError => e
            # Handle missing blob file specific errors
            Rails.logger.error "[ShopifyBatch] Product #{id} has missing image files: #{e.message}"
            failed_products << { id: id, error: "Missing image files: #{e.message}", error_class: e.class.name }
          rescue => e
            # Handle other errors while gathering product data
            Rails.logger.error "[ShopifyBatch] Error preparing product #{id}: #{e.class} - #{e.message}"
            failed_products << { id: id, error: e.message, error_class: e.class.name }
          end
        end

        # Log how many products we're actually processing
        valid_product_count = products_data.size
        Rails.logger.info "[ShopifyBatch] Found #{valid_product_count} valid products to process out of #{product_ids.size} provided"

        # Log any products that failed during preparation
        if failed_products.any?
          failed_ids = failed_products.map { |p| p[:id] }
          error_message = "Failed to prepare #{failed_products.size} products: #{failed_ids.join(", ")}"
          Rails.logger.error "[ShopifyBatch] #{error_message}"

          # Create a notification about the initial failures
          NotificationService.create(
            shop: @shop,
            title: "Products Failed Initial Preparation",
            message: "Some products could not be prepared for Shopify listing. #{error_message}",
            category: "bulk_listing",
            status: "warning"
          )
        end

        # If we have no valid products to process, end here
        if products_data.empty?
          Rails.logger.warn "[ShopifyBatch] No valid products to process after filtering"
          update_batch_status("completed", 0, failed_products.size)
          return
        end

        # Step 2: Process all images in bulk if we have any
        if image_uploads.any?
          Rails.logger.info "[ShopifyBatch] Processing #{image_uploads.size} images for #{products_data.size} products"
          # Don't let image processing failures fail the entire batch
          begin
            process_images_in_bulk(image_uploads)
          rescue => e
            # Log the error but continue with products
            Rails.logger.error "[ShopifyBatch] Error during bulk image processing: #{e.class} - #{e.message}\n#{e.backtrace.first(10).join("\n")}"

            # Create a notification about the image processing failure
            NotificationService.create(
              shop: @shop,
              title: "Image Processing Issues",
              message: "Encountered problems processing some product images: #{e.message}. Products will be created without these images.",
              category: "bulk_listing",
              status: "warning"
            )
          end
        end

        # Step 3: Create products with prepared image URLs (whatever we were able to process)
        Rails.logger.info "[ShopifyBatch] Creating #{products_data.size} products with prepared image URLs"
        create_products_in_bulk(products_data)

      rescue => e
        # This should now only handle truly unexpected errors, not ActiveStorage issues
        Rails.logger.error "[ShopifyBatch] Unexpected error: #{e.class} - #{e.message}\n#{e.backtrace.first(10).join("\n")}"
        handle_batch_failure(e)
        update_batch_status("completed", 0, product_ids.size)
      end
    end

    def process_images_in_bulk(image_uploads)
      return if image_uploads.empty?

      # Step 1: Create all staged uploads in batches
      Rails.logger.info "[ShopifyBatch] Creating staged uploads for #{image_uploads.size} images"
      staged_uploads = []

      # Keep track of which uploads failed due to file issues
      failed_uploads = []

      image_uploads.each_slice(10) do |batch|
        begin
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

          # Create staged uploads with retries for SSL issues
          with_retries(ssl_retry: true, operation: "staged upload creation") do
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
        rescue ActiveStorage::FileNotFoundError => e
          # Handle missing blob file errors for a batch
          batch.each do |upload|
            Rails.logger.error "[ShopifyBatch] File not found for product #{upload[:product_id]}, image: #{upload[:image].filename}"
            failed_uploads << {
              product_id: upload[:product_id],
              error: "File not found: #{upload[:image].filename}",
              error_class: e.class.name
            }
          end
        rescue => e
          # Handle other errors for this batch
          Rails.logger.error "[ShopifyBatch] Error processing staged uploads batch: #{e.class} - #{e.message}"
          batch.each do |upload|
            failed_uploads << {
              product_id: upload[:product_id],
              error: "Batch upload error: #{e.message}",
              error_class: e.class.name
            }
          end
        end
      end

      # Step 2: Upload files to all staged URLs and map resource URLs to products
      Rails.logger.info "[ShopifyBatch] Uploading #{staged_uploads.size} images to staged URLs"

      successful_uploads = 0
      staged_uploads.each do |upload_data|
        begin
          image_data = upload_data[:image_data]
          staged_target = upload_data[:staged_target]

          # Convert parameters array to hash
          params = staged_target["parameters"].each_with_object({}) do |param, hash|
            hash[param["name"]] = param["value"]
          end

          # Upload the image with retries for SSL issues
          success = false
          begin
            image_data[:image].blob.open do |file|
              with_retries(ssl_retry: true, operation: "image upload") do
                response = HTTParty.post(
                  staged_target["url"],
                  multipart: true,
                  body: params.merge("file" => file),
                  timeout: 60,  # Increase timeout for large uploads
                  open_timeout: 30  # Increase connection timeout
                )

                if response.success?
                  # Store the resource URL with the product data
                  resource_url = staged_target["resourceUrl"]
                  image_data[:product_data][:image_urls] << {
                    resource_url: resource_url,
                    alt: image_data[:alt]
                  }
                  success = true
                  successful_uploads += 1
                  Rails.logger.info "[ShopifyBatch] Successfully uploaded image for product #{image_data[:product_id]}"
                else
                  Rails.logger.error "[ShopifyBatch] Failed to upload image: #{response.code} - #{response.body}"
                  raise "HTTP Error: #{response.code} - #{response.body}" if response.code >= 500
                end
              end
            end
          rescue ActiveStorage::FileNotFoundError => e
            # Handle missing blob file
            Rails.logger.error "[ShopifyBatch] File not found for product #{image_data[:product_id]}, image: #{image_data[:image].filename}"
            failed_uploads << {
              product_id: image_data[:product_id],
              error: "File not found: #{image_data[:image].filename}",
              error_class: e.class.name
            }
          rescue => e
            Rails.logger.error "[ShopifyBatch] Error processing image upload: #{e.class} - #{e.message}"
            failed_uploads << {
              product_id: image_data[:product_id],
              error: e.message,
              error_class: e.class.name
            }
          end

          unless success
            Rails.logger.error "[ShopifyBatch] Image upload failed for product #{image_data[:product_id]}"
          end
        rescue => e
          # Catch any unexpected errors during the outer process
          Rails.logger.error "[ShopifyBatch] Unexpected error during image processing: #{e.class} - #{e.message}"
          failed_uploads << {
            product_id: upload_data[:image_data][:product_id],
            error: "Unexpected error: #{e.message}",
            error_class: e.class.name
          }
        end
      end

      Rails.logger.info "[ShopifyBatch] Completed image uploads: #{successful_uploads}/#{staged_uploads.size} successful"

      # Log information about failed uploads if any
      if failed_uploads.any?
        failed_product_ids = failed_uploads.map { |f| f[:product_id] }.uniq

        error_message = "Failed to process images for #{failed_product_ids.size} products: #{failed_product_ids.join(", ")}"
        Rails.logger.error "[ShopifyBatch] #{error_message}"

        # Create a notification about the failures
        NotificationService.create(
          shop: @shop,
          title: "Shopify Batch Image Issues",
          message: "Some product images could not be processed. These products will be created without images. #{error_message}",
          category: "bulk_listing",
          status: "warning"
        )
      end
    end

    def create_products_in_bulk(products_data)
      # Filter out products with no data
      products_data = products_data.select { |data| data[:product].present? }
      return if products_data.empty?

      # First check if there's already a bulk operation running
      if bulk_operation_in_progress?
        # If we're already retrying too many times, give up
        if @retries >= BULK_OP_MAX_RETRIES
          Rails.logger.error "[ShopifyBatch] Failed after #{@retries} attempts - a bulk operation is still in progress"
          update_batch_status("completed", 0, products_data.size)
          return handle_batch_failure("Cannot start bulk operation - another operation is already in progress and didn't complete after multiple retries")
        end

        # Calculate exponential backoff delay with jitter
        base_delay = [ BULK_OP_INITIAL_RETRY_DELAY * (2 ** @retries), BULK_OP_MAX_DELAY ].min
        # Add some random jitter (±20%) to avoid thundering herd
        actual_delay = (base_delay * (0.8 + rand * 0.4)).to_i.seconds

        @retries += 1
        Rails.logger.info "[ShopifyBatch] A bulk operation is already in progress. Retrying job in #{actual_delay.to_i} seconds (attempt #{@retries}/#{BULK_OP_MAX_RETRIES})"

        # Try to get info about the running operation for better debugging
        if @retries % 3 == 0  # Only log details every 3rd retry to avoid spam
          operation_info = get_current_operation_info
          if operation_info
            status = operation_info["status"]
            created_at = operation_info["createdAt"]
            Rails.logger.info "[ShopifyBatch] Current operation (blocking us): ID #{operation_info["id"]}, status: #{status}, created: #{created_at}"
          end
        end

        # Create a new delayed job for retry
        self.class.perform_later(
          shop_id: @shop.id,
          product_ids: products_data.map { |d| d[:product].id },
          batch_index: @batch_index,
          total_batches: @total_batches
        )

        # Sleep in the current job to provide the delay
        sleep actual_delay

        # Return from the current job without completing it
        return
      end

      # Now proceed with the bulk operation as before
      # Prepare JSONL data for bulk operation
      jsonl_data = products_data.map do |data|
        product = data[:product]

        # Use ListingService to prepare product data
        service = Shopify::ListingService.new(product)

        # Add a special tag to identify the Kuralis product ID
        kuralis_id_tag = "kuralis:#{product.id}"
        product_tags = product.tags || []
        product_tags = product_tags + [ kuralis_id_tag ]

        product_input = {
          synchronous: true,
          productSet: {
            title: product.title,
            descriptionHtml: service.build_item_description,
            tags: product_tags,
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

      # Create staged upload for the JSONL file with SSL retry
      staged_upload = nil
      with_retries(ssl_retry: true, operation: "product data staged upload") do
        staged_upload = create_staged_upload(jsonl_data)
      end

      unless staged_upload
        Rails.logger.error "[ShopifyBatch] Failed to create staged upload for product data"
        update_batch_status("completed", 0, products_data.size)
        return handle_batch_failure("Failed to create staged upload for product data")
      end

      # Extract the path from the key parameter
      upload_path = staged_upload["parameters"].find { |p| p["name"] == "key" }&.dig("value")
      unless upload_path
        Rails.logger.error "[ShopifyBatch] Failed to extract upload path from staged upload"
        update_batch_status("completed", 0, products_data.size)
        return handle_batch_failure("Failed to extract upload path from staged upload")
      end

      # Start bulk operation for product creation with SSL retry
      mutation = <<~GQL
        mutation {
          bulkOperationRunMutation(
            mutation: """
              mutation createProduct($productSet: ProductSetInput!, $synchronous: Boolean!) {
                productSet(synchronous: $synchronous, input: $productSet) {
                  product {
                    id
                    handle
                    tags
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

      response = nil
      with_retries(ssl_retry: true, operation: "bulk operation creation") do
        response = @client.query(query: mutation)
      end

      Rails.logger.info "[ShopifyBatch] Bulk product creation operation response: #{response.body}"

      # Check if we got an error about an existing bulk operation
      if response.body["data"]&.dig("bulkOperationRunMutation", "userErrors")&.any? { |e| e["message"]&.include?("already in progress") }
        # If we're already retrying too many times, give up
        if @retries >= BULK_OP_MAX_RETRIES
          Rails.logger.error "[ShopifyBatch] Failed after #{@retries} attempts - a bulk operation is still in progress"
          update_batch_status("completed", 0, products_data.size)
          return handle_batch_failure("Cannot start bulk operation - another operation is already in progress and didn't complete after multiple retries")
        end

        # Use a simple fixed delay with a little jitter
        delay = 60.seconds + (rand * 10).seconds
        @retries += 1

        Rails.logger.info "[ShopifyBatch] A bulk operation is already in progress. Retrying job in #{delay.to_i} seconds (attempt #{@retries}/#{BULK_OP_MAX_RETRIES})"

        # Create a new delayed job for retry
        self.class.perform_later(
          shop_id: @shop.id,
          product_ids: products_data.map { |d| d[:product].id },
          batch_index: @batch_index,
          total_batches: @total_batches
        )

        # Sleep in the current job to provide the delay
        sleep delay

        # Return from the current job without completing it
        nil
      elsif response.body["data"]&.dig("bulkOperationRunMutation", "bulkOperation")
        operation = response.body["data"]["bulkOperationRunMutation"]["bulkOperation"]

        # Wait for bulk operation to complete and process results
        monitor_then_process_bulk_operation(operation, products_data.map { |d| d[:product].id })
      else
        # Check for user errors in the response
        user_errors = response.body["data"]&.dig("bulkOperationRunMutation", "userErrors") || []
        error_message = user_errors.map { |e| e["message"] }.join(", ")

        Rails.logger.error "[ShopifyBatch] Failed to create bulk product operation: #{error_message}"
        update_batch_status("completed", 0, products_data.size)
        handle_batch_failure("Failed to create bulk product operation: #{error_message}")
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

      response = nil
      with_retries(ssl_retry: true, operation: "staged upload creation") do
        response = @client.query(
          query: mutation,
          variables: variables
        )
      end

      staged_target = response.body["data"]["stagedUploadsCreate"]["stagedTargets"].first
      return nil unless staged_target

      # Upload the file with SSL retry
      success = false
      with_retries(ssl_retry: true, operation: "file upload to staged URL") do
        success = upload_to_url(staged_target, data)
      end

      success ? staged_target : nil
    end

    def monitor_then_process_bulk_operation(operation, product_ids)
      loop do
        status = nil
        with_retries(ssl_retry: true, operation: "bulk operation status check") do
          status = check_bulk_operation_status(operation["id"])
        end

        Rails.logger.info "[ShopifyBatch] Bulk operation status: #{status}"

        case status["status"]
        when "COMPLETED"
          Rails.logger.info "[ShopifyBatch] Bulk operation completed, processing results"
          if status["url"]
            # Download and process the JSONL file with SSL retry
            response = nil
            with_retries(ssl_retry: true, operation: "download bulk operation results") do
              response = HTTParty.get(status["url"])
            end

            if response.success?
              process_bulk_operation_results(response.body, product_ids)
            else
              Rails.logger.error "[ShopifyBatch] Failed to download bulk operation results: #{response.code}"
              update_batch_status("completed", 0, product_ids.size)
              handle_batch_failure("Failed to download bulk operation results")
            end
          else
            Rails.logger.error "[ShopifyBatch] No URL provided in completed bulk operation"
            update_batch_status("completed", 0, product_ids.size)
            handle_batch_failure("No URL provided in completed bulk operation")
          end
          break
        when "FAILED"
          Rails.logger.error "[ShopifyBatch] Bulk operation failed: #{status["errorCode"]}"
          update_batch_status("completed", 0, product_ids.size)
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

          # Extract tags from the product data to find our kuralis_id tag
          product_id = nil

          # First try to find the product ID from the tags
          if product_data["tags"]
            kuralis_id_tag = product_data["tags"].find { |tag| tag.start_with?("kuralis:") }
            if kuralis_id_tag
              product_id = kuralis_id_tag.split(":").last.to_i
              Rails.logger.info "[ShopifyBatch] Found Kuralis ID #{product_id} in product tags"
            end
          end

          # If we couldn't find the ID in tags, try to find by title
          if product_id.nil?
            Rails.logger.warn "[ShopifyBatch] Could not find Kuralis ID in tags for product: #{product_data["id"]}, trying to match by title"
            product_title = product_data["title"] || ""
            matching_product = KuralisProduct.find_by(title: product_title, shop_id: @shop.id)

            if matching_product
              product_id = matching_product.id
              Rails.logger.info "[ShopifyBatch] Found matching Kuralis product by title: #{product_title} (ID: #{product_id})"
            else
              Rails.logger.error "[ShopifyBatch] Could not find matching Kuralis product by title: #{product_title}"
              results << OpenStruct.new(
                success?: false,
                errors: [ "Missing Kuralis ID tag and no matching product found by title. Product created in Shopify but not linked to Kuralis." ]
              )
              next
            end
          end

          # Find the product by ID
          begin
            product = KuralisProduct.find(product_id)

            shopify_product_id = product_data["id"].split("/").last
            handle = product_data["handle"]
            variant_id = variant_data["inventoryItem"]["id"].split("/").last

            shopify_product = product.create_shopify_product!(
              shop: @shop,
              shopify_product_id: shopify_product_id,
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
                begin
                  image.blob.open do |tempfile|
                    shopify_product.images.attach(
                      io: tempfile,
                      filename: image.filename.to_s,
                      content_type: image.content_type,
                      identify: false
                    )
                  end
                rescue ActiveStorage::FileNotFoundError => e
                  Rails.logger.error "[ShopifyBatch] Could not attach image to Shopify product: #{e.message} (product ID: #{product.id})"
                rescue => e
                  Rails.logger.error "[ShopifyBatch] Error attaching image to Shopify product: #{e.class} - #{e.message} (product ID: #{product.id})"
                end
              end
            end

            results << OpenStruct.new(success?: true)
          rescue => e
            Rails.logger.error "[ShopifyBatch] Error processing product creation: #{e.class} - #{e.message}"
            results << OpenStruct.new(
              success?: false,
              errors: [ e.message ]
            )
          end
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

      # Update batch tracking information
      update_batch_status("completed", successful, failed)

      # Create batch-specific notification
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

        # Upload the file using HTTParty with longer timeouts
        response = self.class.post(
          uri.to_s,
          multipart: true,
          body: params.merge(
            file: File.open(file.path)
          ),
          timeout: 120,  # Increase timeout for large uploads
          open_timeout: 30  # Increase connection timeout
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

    def handle_batch_failure(error, additional_message = nil)
      error_message = error.is_a?(Exception) ? "#{error.class}: #{error.message}" : error.to_s
      error_message += ". #{additional_message}" if additional_message

      Rails.logger.error "[ShopifyBatch] Batch failure: #{error_message}"

      NotificationService.create(
        shop: @shop,
        title: "Shopify Batch #{@batch_index + 1} Failed",
        message: "Batch failed: #{error_message}. Please check logs for details.",
        category: "bulk_listing",
        status: "error"
      )
    end

    def bulk_operation_in_progress?
      operation_info = get_current_operation_info

      if operation_info
        status = operation_info["status"]

        if status == "RUNNING" || status == "CREATED"
          # Check if it's been running for a very long time (over 10 minutes)
          # If so, we might want to consider it stalled and proceed anyway
          created_at = Time.parse(operation_info["createdAt"]) rescue nil

          if created_at
            running_time = Time.now.utc - created_at

            # If operation has been running for more than 10 minutes and we've retried at least 5 times,
            # or if it's been running for more than 30 minutes regardless of retries,
            # consider it stalled and proceed
            if (running_time > 10.minutes && @retries > 5) || running_time > 30.minutes
              Rails.logger.warn "[ShopifyBatch] Found stalled bulk operation (running for #{running_time.to_i / 60} minutes). Proceeding anyway."
              return false
            end
          end

          Rails.logger.info "[ShopifyBatch] Found existing bulk operation: #{operation_info["id"]} (status: #{status}, type: #{operation_info["type"]})"
          return true
        else
          Rails.logger.info "[ShopifyBatch] Found bulk operation that's not running: #{operation_info["id"]} (status: #{status})"
        end
      end

      false
    end

    def get_current_operation_info
      # Query to check for any running bulk operations
      query = <<~GQL
        query {
          currentBulkOperation {
            id
            status
            errorCode
            createdAt
            completedAt
            objectCount
            type
          }
        }
      GQL

      response = nil
      with_retries(ssl_retry: true, operation: "checking for existing bulk operations") do
        response = @client.query(query: query)
      end

      if response.body["data"] && response.body["data"]["currentBulkOperation"]
        return response.body["data"]["currentBulkOperation"]
      end

      nil
    rescue => e
      Rails.logger.error "[ShopifyBatch] Error checking current operation: #{e.message}"
      nil
    end
  end
end
