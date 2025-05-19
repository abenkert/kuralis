class BulkListingJob < ApplicationJob
  queue_as :default

  # Optimal batch size for Shopify bulk operations
  SHOPIFY_BATCH_SIZE = 250  # Shopify's bulk mutation can handle up to 250 items

  # Initial delay between batches (seconds)
  INITIAL_BATCH_SPACING = 60  # Start the first few batches with 1 minute spacing

  # Batch size for chunking product processing
  BATCH_SIZE = 50

  # Main entry point - enqueues a single batch job per platform
  def perform(shop_id:, product_ids:, platforms:, **_kwargs)
    shop = Shop.find(shop_id)

    NotificationService.create(
      shop: shop,
      title: "Bulk Listing Started",
      message: "Started processing #{product_ids.size} products across #{platforms} platforms.",
      category: "bulk_listing",
      status: "info"
    )

    Array(platforms).each do |platform|
      case platform
      when "shopify"
        # Calculate optimal batching
        total_batches = (product_ids.size.to_f / SHOPIFY_BATCH_SIZE).ceil

        # Process batches with initial spacing to avoid conflicts
        # This gives time for the first batch to complete its bulk operation
        # before subsequent batches start trying
        total_batches.times do |batch_index|
          start_idx = batch_index * SHOPIFY_BATCH_SIZE
          batch_ids = product_ids[start_idx, SHOPIFY_BATCH_SIZE].compact

          next if batch_ids.empty?

          # Space out the first few batches to avoid initial conflicts
          # Later batches will rely on the retry mechanism
          delay = batch_index < 3 ? (batch_index * INITIAL_BATCH_SPACING) : 0

          Shopify::BatchCreateListingsJob.set(wait: delay.seconds).perform_later(
            shop_id: shop.id,
            product_ids: batch_ids,
            batch_index: batch_index,
            total_batches: total_batches
          )

          Rails.logger.info "Queued Shopify batch #{batch_index + 1}/#{total_batches} with #{batch_ids.size} products (delay: #{delay}s)"
        end

      when "ebay"
        product_ids.each_slice(BATCH_SIZE).with_index do |batch_ids, batch_index|
          Ebay::BatchCreateListingsJob.perform_later(
            shop_id: shop.id,
            product_ids: batch_ids
          )
          Rails.logger.info "Queued batch #{batch_index + 1} (#{batch_ids.size} products) for eBay listing."
        end
      end
    end

    NotificationService.create(
      shop: shop,
      title: "Bulk Listing Jobs Queued",
      message: "Successfully queued all batches for processing. You'll receive progress notifications.",
      category: "bulk_listing",
      status: "info"
    )
  end
end
