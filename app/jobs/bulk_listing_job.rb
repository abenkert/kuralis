class BulkListingJob < ApplicationJob
  queue_as :default

  # Optimal batch size for Shopify bulk operations
  SHOPIFY_BATCH_SIZE = 250  # Shopify's bulk mutation can handle up to 250 items
  CONCURRENT_JOBS = 2      # Limit concurrent jobs to avoid overwhelming rate limits

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
        batch_groups = total_batches.times.each_slice(CONCURRENT_JOBS).to_a

        # Process in controlled concurrent groups
        batch_groups.each_with_index do |group_indices, group_index|
          group_indices.each do |batch_index|
            start_idx = batch_index * SHOPIFY_BATCH_SIZE
            batch_ids = product_ids[start_idx, SHOPIFY_BATCH_SIZE].compact

            next if batch_ids.empty?

            Shopify::BatchCreateListingsJob.set(
              wait: (group_index * 5).seconds  # Stagger groups by 5 seconds
            ).perform_later(
              shop_id: shop.id,
              product_ids: batch_ids,
              batch_index: batch_index,
              total_batches: total_batches
            )

            Rails.logger.info "Queued Shopify batch #{batch_index + 1}/#{total_batches} with #{batch_ids.size} products"
          end
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
