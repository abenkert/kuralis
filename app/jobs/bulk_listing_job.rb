class BulkListingJob < ApplicationJob
  queue_as :default

  # Batch size for chunking product processing
  BATCH_SIZE = 50

  # Main entry point - breaks down job into batches
  def perform(shop_id:, product_ids:, platforms:, batch_index: 0, total_batches: nil)
    shop = Shop.find(shop_id)

    # First-time setup for a large bulk operation
    if batch_index == 0
      # Calculate number of batches needed
      chunked_product_ids = product_ids.each_slice(BATCH_SIZE).to_a
      total_batches = chunked_product_ids.size

      # Create initial notification
      NotificationService.create(
        shop: shop,
        title: "Bulk Listing Started",
        message: "Started processing #{product_ids.size} products across #{platforms} platforms in #{total_batches} batches.",
        category: "bulk_listing",
        status: "info"
      )

      # Schedule all the batch jobs
      chunked_product_ids.each_with_index do |chunk_ids, index|
        if index == 0
          # Process first batch immediately (current job)
          process_batch(shop, chunk_ids, platforms, index, total_batches)
        else
          # Schedule other batches as separate jobs
          self.class.set(wait: 5.seconds).perform_later(
            shop_id: shop_id,
            product_ids: chunk_ids,
            platforms: platforms,
            batch_index: index,
            total_batches: total_batches
          )
        end
      end
    else
      # This is a continuation batch job
      process_batch(shop, product_ids, platforms, batch_index, total_batches)
    end
  end

  private

  # Process a single batch of products
  def process_batch(shop, product_ids, platforms, batch_index, total_batches)
    # Track results per platform for this batch
    results = Hash.new { |h, k| h[k] = { count: 0 } }

    # Get products for this batch
    products = shop.kuralis_products.where(id: product_ids)

    begin
      Rails.logger.info "Processing bulk listing batch #{batch_index + 1}/#{total_batches} with #{products.size} products"

      # Group products by platform
      shopify_product_ids = []
      ebay_product_ids = []

      products.find_each do |product|
        Array(platforms).each do |platform|
          case platform
          when "shopify"
            next if product.shopify_product.present?
            shopify_product_ids << product.id
            results[platform][:count] += 1

          when "ebay"
            next if product.ebay_listing.present?
            ebay_product_ids << product.id
            results[platform][:count] += 1
          end
        end
      end

      # Schedule platform-specific batch jobs for collected products
      if shopify_product_ids.any? && platforms.include?("shopify")
        Shopify::BatchCreateListingsJob.perform_later(
          shop_id: shop.id,
          product_ids: shopify_product_ids
        )

        Rails.logger.info "Queued #{shopify_product_ids.size} products for Shopify listing"
      end

      if ebay_product_ids.any? && platforms.include?("ebay")
        Ebay::BatchCreateListingsJob.perform_later(
          shop_id: shop.id,
          product_ids: ebay_product_ids
        )

        Rails.logger.info "Queued #{ebay_product_ids.size} products for eBay listing"
      end

      # If this is the final batch, send completion notification
      if batch_index == total_batches - 1
        # Create final notification
        message = "Completed bulk listing processing.\n"

        Array(platforms).each do |platform|
          total = results[platform][:count]
          message += "- #{platform.titleize}: #{total} products queued for listing\n"
        end

        message += "\nPlatform-specific jobs are now processing these products. You'll receive additional notifications when they complete."

        NotificationService.create(
          shop: shop,
          title: "Bulk Listing Processing Complete",
          message: message,
          category: "bulk_listing",
          status: "info"
        )
      end
    rescue => e
      Rails.logger.error "Error processing bulk listing batch #{batch_index + 1}: #{e.message}"
      raise # Re-raise to trigger job retry mechanism
    end
  end
end
