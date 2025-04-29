module Shopify
  class BatchCreateListingsJob < ApplicationJob
    queue_as :shopify

    # Optional batch size to process in chunks with a pause between
    BATCH_SIZE = 50
    # Minimum points to keep as a buffer to avoid hitting the limit
    RATE_LIMIT_BUFFER = 100

    def perform(shop_id:, product_ids:)
      shop = Shop.find(shop_id)

      # Track success/failure counts
      successful = 0
      failed = 0

      product_ids.each_slice(BATCH_SIZE).with_index do |batch_ids, batch_index|
        batch_ids.each do |product_id|
          begin
            product = KuralisProduct.find(product_id)
            service = Shopify::ListingService.new(product)
            response = service.create_listing

            # Inspect rate limit info from the response
            cost_info = response.body.dig("extensions", "cost", "throttleStatus")
            if cost_info
              currently_available = cost_info["currentlyAvailable"]
              restore_rate = cost_info["restoreRate"]
              actual_query_cost = response.body.dig("extensions", "cost", "actualQueryCost")

              Rails.logger.info "Shopify rate limit: #{currently_available} available, restore rate: #{restore_rate}, last query cost: #{actual_query_cost}"

              if currently_available < RATE_LIMIT_BUFFER
                points_needed = RATE_LIMIT_BUFFER - currently_available
                wait_seconds = (points_needed.to_f / restore_rate).ceil
                Rails.logger.info "Waiting #{wait_seconds}s for Shopify rate limit to restore"
                sleep(wait_seconds)
              end
            end

            # Check for errors in the response
            user_errors = response.body.dig("data", "productSet", "userErrors")
            if user_errors.present? && user_errors.any?
              Rails.logger.error "Shopify user errors: #{user_errors.inspect}"
              failed += 1
            else
              successful += 1
            end

          rescue => e
            # If we get a throttle error, back off and retry
            if e.message.include?("rate limit") || e.message.include?("throttled")
              Rails.logger.warn "Hit Shopify rate limit, backing off"
              sleep(30)
              retry
            else
              failed += 1
              Rails.logger.error "Failed to create Shopify listing for product #{product_id}: #{e.message}"
            end
          end
        end

        # Pause between batches to avoid overwhelming the API
        if batch_index < (product_ids.size.to_f / BATCH_SIZE).ceil - 1
          Rails.logger.info "Completed batch #{batch_index + 1}, waiting before starting next batch"
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
