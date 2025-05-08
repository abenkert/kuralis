module Shopify
  class BatchCreateListingsJob < ApplicationJob
    queue_as :shopify

    # Optional batch size to process in chunks with a pause between
    BATCH_SIZE = 50
    # Minimum points to keep as a buffer to avoid hitting the limit
    RATE_LIMIT_BUFFER = 100

    def perform(shop_id:, product_ids:)
      shop = Shop.find(shop_id)

      # Initialize the rate limiter
      rate_limiter = Shopify::RateLimiterService.new(shop_id)

      # Track success/failure counts
      successful = 0
      failed = 0

      product_ids.each_slice(BATCH_SIZE).with_index do |batch_ids, batch_index|
        batch_ids.each do |product_id|
          begin
            Rails.logger.info "[ShopifyBatch] Attempting to create Shopify listing for product #{product_id}"
            product = KuralisProduct.find(product_id)
            service = Shopify::ListingService.new(product)

            # Wait for enough points before making the Shopify API call
            rate_limiter.wait_for_points!(60) # Assume 50 points per call as a safe default
            response = service.create_listing
            next if response == false

            # Inspect rate limit info from the response
            cost_info = response.body.dig("extensions", "cost", "throttleStatus")
            rate_limiter.update_from_throttle_status(cost_info)
            if cost_info
              currently_available = cost_info["currentlyAvailable"]
              restore_rate = cost_info["restoreRate"]
              actual_query_cost = response.body.dig("extensions", "cost", "actualQueryCost")

              Rails.logger.info "[ShopifyBatch] Rate limit: #{currently_available} available, restore rate: #{restore_rate}, last query cost: #{actual_query_cost}"

              if currently_available < RATE_LIMIT_BUFFER
                points_needed = RATE_LIMIT_BUFFER - currently_available
                wait_seconds = (points_needed.to_f / restore_rate).ceil
                Rails.logger.info "[ShopifyBatch] Waiting #{wait_seconds}s for Shopify rate limit to restore"
                sleep(wait_seconds)
              end
            end

            # Enhanced error handling
            top_level_errors = response.body["errors"]
            user_errors = response.body.dig("data", "productSet", "userErrors")
            product_data = response.body.dig("data", "productSet", "product")

            if top_level_errors.present?
              Rails.logger.error "[ShopifyBatch] Top-level Shopify errors for product #{product_id}: #{top_level_errors.inspect} | Response: #{response.body.inspect}"
              failed += 1
            elsif user_errors.present? && user_errors.any?
              Rails.logger.error "[ShopifyBatch] Shopify user errors for product #{product_id}: #{user_errors.inspect} | Response: #{response.body.inspect}"
              failed += 1
            elsif product_data.nil?
              Rails.logger.error "[ShopifyBatch] No product returned for product #{product_id} and no user errors. Full response: #{response.body.inspect}"
              failed += 1
            else
              Rails.logger.info "[ShopifyBatch] Successfully created Shopify listing for product #{product_id}"
              successful += 1
            end

          rescue => e
            # If we get a throttle error, back off and retry
            if e.message.include?("rate limit") || e.message.include?("throttled")
              Rails.logger.warn "[ShopifyBatch] Hit Shopify rate limit for product #{product_id}, backing off"
              sleep(30)
              retry
            else
              failed += 1
              Rails.logger.error "[ShopifyBatch] Exception for product #{product_id}: #{e.class} - #{e.message}\n#{e.backtrace.first(10).join("\n")}"
            end
          end
        end

        # Pause between batches to avoid overwhelming the API
        if batch_index < (product_ids.size.to_f / BATCH_SIZE).ceil - 1
          Rails.logger.info "[ShopifyBatch] Completed batch #{batch_index + 1}, waiting before starting next batch"
          sleep(5)
        end
      end

      # Create a notification with results
      NotificationService.create(
        shop: shop,
        title: "Shopify Batch Listing Complete",
        message: "Processed #{product_ids.size} products: #{successful} successful, #{failed} failed.",
        category: "bulk_listing",
        status: failed > 0 ? "warning" : "success"
      )
    end
  end
end
