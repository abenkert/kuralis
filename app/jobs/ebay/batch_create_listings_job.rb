module Ebay
  class BatchCreateListingsJob < ApplicationJob
    queue_as :ebay

    # Optional batch size to process in chunks with a pause between
    # Use a smaller batch size for eBay due to stricter rate limits
    BATCH_SIZE = 20

    def perform(shop_id:, product_ids:)
      shop = Shop.find(shop_id)

      # Track success/failure counts
      successful = 0
      failed = 0

      # Process products in batches to avoid overwhelming the system
      product_ids.each_slice(BATCH_SIZE).with_index do |batch_ids, batch_index|
        batch_ids.each do |product_id|
          begin
            # Simply call the existing service/job for each product
            product = KuralisProduct.find(kuralis_product_id)

            service = Ebay::ListingService.new(product)
            service.create_listing

            # Track success
            successful += 1

          rescue => e
            # Log failure but continue with next product
            failed += 1
            Rails.logger.error "Failed to create eBay listing for product #{product_id}: #{e.message}"
          end
        end

        # Pause between batches to avoid overwhelming the API
        # Use longer pause for eBay due to stricter rate limits
        if batch_index < (product_ids.size.to_f / BATCH_SIZE).ceil - 1
          sleep(2)

          # Log progress
          Rails.logger.info "eBay batch listing progress: #{successful + failed}/#{product_ids.size} processed (#{successful} successful, #{failed} failed)"
        end
      end

      # Create a notification with results
      NotificationService.create(
        shop: shop,
        title: "eBay Batch Listing Complete",
        message: "Processed #{product_ids.size} products: #{successful} successful, #{failed} failed.",
        category: "bulk_listing",
        status: failed > 0 ? "warning" : "success"
      )
    end
  end
end
