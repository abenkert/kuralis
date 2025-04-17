class BatchCacheKuralisProductImagesJob < ApplicationJob
  queue_as :images

  def perform(shop_id, product_ids)
    return if product_ids.blank?

    shop = Shop.find_by(id: shop_id)
    return unless shop

    Rails.logger.info "Processing image caching for batch of #{product_ids.size} products"

    # Fetch all products at once to reduce DB queries
    products = KuralisProduct.where(id: product_ids).includes(:ebay_listing)

    products.each do |product|
      # Skip if images are already attached
      next if product.images.attached?

      begin
        # Check if this product has an associated eBay listing with images
        if product.ebay_listing_id.present? &&
           product.ebay_listing &&
           product.ebay_listing.images.attached?

          # Copy images from eBay listing instead of re-downloading
          copy_images_from_ebay_listing(product, product.ebay_listing)
          Rails.logger.debug "Copied attached images from eBay listing #{product.ebay_listing_id} to KuralisProduct #{product.id}"
        elsif product.image_urls.present?
          # Fallback to traditional URL-based image caching if necessary
          product.cache_images
          Rails.logger.debug "Cached images from URLs for KuralisProduct #{product.id}"
        end
      rescue => e
        Rails.logger.error "Failed to cache images for KuralisProduct #{product.id}: #{e.message}"
      end
    end

    Rails.logger.info "Completed image caching for batch of #{product_ids.size} products"
  end

  private

  def copy_images_from_ebay_listing(product, ebay_listing)
    ebay_listing.images.each do |image|
      # Create a new attachment that points to the same blob
      product.images.attach(image.blob)
    end

    product.update(images_last_synced_at: Time.current)
  end
end
