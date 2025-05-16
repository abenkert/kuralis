class BatchCacheKuralisProductImagesJob < ApplicationJob
  queue_as :images

  def perform(shop_id, product_ids)
    return if product_ids.blank?

    shop = Shop.find_by(id: shop_id)
    return unless shop

    Rails.logger.info "Processing image caching for batch of #{product_ids.size} products"

    # Fetch all products at once to reduce DB queries
    products = KuralisProduct.where(id: product_ids).includes(:ebay_listing)

    Rails.logger.info "Found #{products.size} products to process"

    products.each do |product|
      # Log the product we're processing
      Rails.logger.info "Processing product ID: #{product.id}, title: #{product.title}"

      # Skip if images are already attached, but log this decision
      if product.images.attached?
        Rails.logger.info "Skipping product #{product.id} - already has #{product.images.count} images attached"
        next
      end

      begin
        # Check if this product has an associated eBay listing with images
        if product.ebay_listing_id.present?
          # Explicitly fetch the ebay listing to ensure we have it
          ebay_listing = EbayListing.find_by(id: product.ebay_listing_id)

          if ebay_listing.nil?
            Rails.logger.warn "Product #{product.id} has ebay_listing_id #{product.ebay_listing_id} but listing not found"
            next
          end

          # Check if the ebay listing has images
          if ebay_listing.images.attached?
            Rails.logger.info "eBay listing #{ebay_listing.id} has #{ebay_listing.images.count} images, copying to product #{product.id}"

            # Copy images from eBay listing instead of re-downloading
            copy_images_from_ebay_listing(product, ebay_listing)
            Rails.logger.info "Successfully copied #{ebay_listing.images.count} images from eBay listing #{ebay_listing.id} to KuralisProduct #{product.id}"
          else
            Rails.logger.warn "eBay listing #{ebay_listing.id} has no attached images for product #{product.id}"

            # Fallback to URL-based images if available
            if product.image_urls.present?
              Rails.logger.info "Falling back to URL-based images for product #{product.id}"
              product.cache_images
              Rails.logger.info "Cached images from URLs for KuralisProduct #{product.id}"
            end
          end
        elsif product.image_urls.present?
          # Fallback to traditional URL-based image caching if necessary
          Rails.logger.info "No eBay listing found, using image URLs for product #{product.id}"
          product.cache_images
          Rails.logger.info "Cached images from URLs for KuralisProduct #{product.id}"
        else
          Rails.logger.warn "Product #{product.id} has no eBay listing with images and no image URLs"
        end
      rescue => e
        Rails.logger.error "Failed to cache images for KuralisProduct #{product.id}: #{e.message}\n#{e.backtrace.join("\n")}"
      end
    end

    Rails.logger.info "Completed image caching for batch of #{product_ids.size} products"
  end

  private

  def copy_images_from_ebay_listing(product, ebay_listing)
    # Count how many images we're copying
    image_count = 0

    ebay_listing.images.each do |image|
      begin
        # Create a new attachment that points to the same blob
        product.images.attach(image.blob)
        image_count += 1
      rescue => e
        Rails.logger.error "Failed to copy image #{image.id} from eBay listing #{ebay_listing.id} to product #{product.id}: #{e.message}"
      end
    end

    if image_count > 0
      begin
        # Use update_columns to bypass validations and only update the timestamp
        product.update_columns(images_last_synced_at: Time.current)
        Rails.logger.info "Successfully copied #{image_count} images to product #{product.id}"
      rescue => e
        Rails.logger.error "Failed to update timestamp for product #{product.id}: #{e.message}"
      end
    else
      Rails.logger.warn "No images were copied to product #{product.id}"
    end
  end
end
