module Shopify
  class BatchCreateListingsJob < ApplicationJob
    queue_as :shopify

    RATE_LIMIT_BUFFER = 200  # Higher buffer for bulk operations
    BULK_MUTATION_COST = 100 # Approximate cost for bulk mutation
    POLL_INTERVAL = 5.seconds # How often to check bulk operation status
    MAX_RETRIES = 3

    def perform(shop_id:, product_ids:, batch_index:, total_batches:)
      @shop = Shop.find(shop_id)
      @rate_limiter = Shopify::RateLimiterService.new(shop_id)
      @batch_index = batch_index
      @total_batches = total_batches
      @retries = 0

      Rails.logger.info "[ShopifyBatch] Starting batch #{batch_index + 1}/#{total_batches} with #{product_ids.size} products"

      process_batch(product_ids)
    end

    private

    def process_batch(product_ids)
      # Prepare products for bulk operation
      products_data = prepare_products_data(product_ids)

      # Wait for sufficient rate limit points
      @rate_limiter.wait_for_points!(BULK_MUTATION_COST)

      # Start bulk operation
      bulk_operation = create_bulk_operation(products_data)

      if bulk_operation
        monitor_bulk_operation(bulk_operation)
        process_bulk_operation_results(bulk_operation)
      else
        handle_bulk_operation_failure(product_ids)
      end
    rescue Shopify::RateLimiterService::RateLimitError => e
      Rails.logger.error "[ShopifyBatch] Rate limit exceeded: #{e.message}"
      if @retries < MAX_RETRIES
        @retries += 1
        wait_time = (2 ** @retries) + rand(10)
        Rails.logger.info "[ShopifyBatch] Retry #{@retries}/#{MAX_RETRIES} after #{wait_time}s"
        sleep wait_time
        retry
      else
        handle_batch_failure("Max retries exceeded")
      end
    rescue => e
      Rails.logger.error "[ShopifyBatch] Unexpected error: #{e.class} - #{e.message}\n#{e.backtrace.first(10).join("\n")}"
      handle_batch_failure(e)
    end

    def prepare_products_data(product_ids)
      products_data = []
      product_ids.each do |id|
        product = KuralisProduct.find(id)
        products_data << build_product_data(product)
      end
      products_data
    end

    def build_product_data(product)
      # Transform your product data into Shopify's expected format
      {
        title: product.title,
        description: product.description,
        variants: product.variants.map { |v| build_variant_data(v) },
        images: product.images.map { |i| build_image_data(i) }
        # Add other necessary product fields
      }
    end

    def create_bulk_operation(products_data)
      mutation = build_bulk_mutation(products_data)
      response = ShopifyAPI::GraphQL.client.execute(mutation)

      if response.data&.bulk_operation_run_mutation&.bulk_operation
        response.data.bulk_operation_run_mutation.bulk_operation
      else
        Rails.logger.error "[ShopifyBatch] Failed to create bulk operation: #{response.errors.inspect}"
        nil
      end
    end

    def monitor_bulk_operation(operation)
      loop do
        status = check_bulk_operation_status(operation.id)
        break if status.completed? || status.failed?

        sleep POLL_INTERVAL
      end
    end

    def process_bulk_operation_results(operation)
      results = fetch_bulk_operation_results(operation)

      successful = results.count { |r| r.success? }
      failed = results.count { |r| !r.success? }

      NotificationService.create(
        shop: @shop,
        title: "Shopify Batch #{@batch_index + 1} Complete",
        message: "Processed #{results.size} products: #{successful} successful, #{failed} failed.",
        category: "bulk_listing",
        status: failed > 0 ? "warning" : "success"
      )

      # Log any failures for investigation
      results.reject(&:success?).each do |result|
        Rails.logger.error "[ShopifyBatch] Product creation failed: #{result.errors.inspect}"
      end
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

    def build_bulk_mutation(products_data)
      <<~GQL
        mutation {
          bulkOperationRunMutation(
            mutation: """
              mutation createProducts($input: ProductInput!) {
                productCreate(input: $input) {
                  product {
                    id
                    title
                    handle
                  }
                  userErrors {
                    field
                    message
                  }
                }
              }
            """,
            stagedUploadPath: #{staged_uploads_path(products_data)}
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
    end

    def staged_uploads_path(products_data)
      # Convert products data to JSONL format
      jsonl_data = products_data.map do |product|
        {
          input: product
        }.to_json
      end.join("\n")

      # Upload to Shopify's staged uploads
      staged_upload = create_staged_upload(jsonl_data)
      staged_upload.path
    end

    def create_staged_upload(data)
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
          filename: "products_#{@batch_index}.jsonl",
          mimeType: "text/jsonl",
          httpMethod: "POST"
        } ]
      }

      response = ShopifyAPI::GraphQL.client.execute(mutation, variables: variables)
      upload_to_url(response.data.staged_uploads_create.staged_targets.first, data)
      response.data.staged_uploads_create.staged_targets.first
    end

    def build_variant_data(variant)
      {
        price: variant.price,
        sku: variant.sku,
        inventoryQuantity: variant.quantity,
        weight: variant.weight,
        weightUnit: variant.weight_unit.upcase,
        option1: variant.option1,
        option2: variant.option2,
        option3: variant.option3,
        inventoryManagement: "SHOPIFY"
      }.compact
    end

    def build_image_data(image)
      {
        src: image.url,
        altText: image.alt_text
      }.compact
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

      response = ShopifyAPI::GraphQL.client.execute(query)
      response.data.node
    end

    def fetch_bulk_operation_results(operation)
      return [] unless operation.url

      # Download and parse the JSONL results
      response = HTTP.get(operation.url)
      results = []

      response.body.each_line do |line|
        result = JSON.parse(line)
        results << OpenStruct.new(
          success?: !result["userErrors"]&.any?,
          errors: result["userErrors"],
          product_id: result.dig("data", "productCreate", "product", "id")
        )
      end

      results
    end

    def upload_to_url(staged_target, data)
      uri = URI.parse(staged_target.url)

      # Prepare parameters from staged target
      params = staged_target.parameters.each_with_object({}) do |param, hash|
        hash[param.name] = param.value
      end

      # Upload the file
      HTTP.post(uri, form: params.merge(file: HTTP::FormData::File.new(StringIO.new(data))))
    end
  end
end
