class CacheKuralisProductImagesJob < ApplicationJob
  queue_as :images
  
  def perform(shop_id, product_id)
    product = KuralisProduct.find_by(id: product_id)
    return unless product
    
    # Skip if images are already attached
    return if product.images.attached?
    
    # Check if this product has an associated eBay listing with images
    if product.ebay_listing_id.present? && 
       (ebay_listing = EbayListing.find_by(id: product.ebay_listing_id)) && 
       ebay_listing.images.attached?
      
      # Copy images from eBay listing instead of re-downloading
      copy_images_from_ebay_listing(product, ebay_listing)
      Rails.logger.info "Successfully copied attached images from eBay listing #{ebay_listing.id} to KuralisProduct #{product.id}"
    elsif product.image_urls.present?
      # Fallback to traditional URL-based image caching if necessary
      product.cache_images
      Rails.logger.info "Successfully cached images from URLs for KuralisProduct #{product.id}"
    end
  rescue => e
    Rails.logger.error "Failed to cache images for KuralisProduct #{product_id}: #{e.message}"
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