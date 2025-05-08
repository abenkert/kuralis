class BulkListingJob < ApplicationJob
  queue_as :default

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
        product_ids.each_slice(BATCH_SIZE).with_index do |batch_ids, batch_index|
          Shopify::BatchCreateListingsJob.perform_later(
            shop_id: shop.id,
            product_ids: batch_ids
          )
          Rails.logger.info "Queued batch \\#{batch_index + 1} (\\#{batch_ids.size} products) for Shopify listing."
        end
      when "ebay"
        product_ids.each_slice(BATCH_SIZE).with_index do |batch_ids, batch_index|
          Ebay::BatchCreateListingsJob.perform_later(
            shop_id: shop.id,
            product_ids: batch_ids
          )
          Rails.logger.info "Queued batch \\#{batch_index + 1} (\\#{batch_ids.size} products) for eBay listing."
        end
      end
    end

    NotificationService.create(
      shop: shop,
      title: "Bulk Listing Processing Complete",
      message: "Queued all products for platform-specific batch jobs. You'll receive additional notifications when they complete.",
      category: "bulk_listing",
      status: "info"
    )
  end
end
