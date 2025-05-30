class BatchCacheKuralisProductImagesJob < ApplicationJob
  queue_as :images

  def perform(shop_id, product_ids)
    return if product_ids.blank?

    shop = Shop.find_by(id: shop_id)
    return unless shop

    Rails.logger.info "=== BATCH IMAGE MIGRATION STARTED ==="
    Rails.logger.info "Processing image caching for batch of #{product_ids.size} products"

    # Fetch all products at once to reduce DB queries
    products = KuralisProduct.where(id: product_ids).includes(:ebay_listing)

    Rails.logger.info "Found #{products.size} products to process"

    success_count = 0
    failed_count = 0
    skipped_count = 0

    products.each do |product|
      begin
        Rails.logger.info "Processing product ID: #{product.id}, title: #{product.title}"

        # Skip if images are already attached
        if product.images.attached?
          Rails.logger.info "Skipping product #{product.id} - already has #{product.images.count} images attached"
          skipped_count += 1
          next
        end

        # Track if we successfully processed this product
        processed = false

        # Strategy 1: Try to copy from eBay listing if available and has images
        if product.ebay_listing_id.present?
          ebay_listing = EbayListing.find_by(id: product.ebay_listing_id)

          if ebay_listing.nil?
            Rails.logger.warn "Product #{product.id} has ebay_listing_id #{product.ebay_listing_id} but listing not found"
          elsif ebay_listing.images.attached?
            Rails.logger.info "eBay listing #{ebay_listing.id} has #{ebay_listing.images.count} images, copying to product #{product.id}"

            if copy_images_from_ebay_listing(product, ebay_listing)
              Rails.logger.info "Successfully copied #{ebay_listing.images.count} images from eBay listing #{ebay_listing.id} to product #{product.id}"
              success_count += 1
              processed = true
            else
              Rails.logger.warn "Failed to copy images from eBay listing #{ebay_listing.id} to product #{product.id}"
            end
          else
            Rails.logger.warn "eBay listing #{ebay_listing.id} has no attached images for product #{product.id}, will try URL fallback"
          end
        end

        # Strategy 2: Fallback to URL-based caching if we haven't processed yet
        if !processed
          if product.image_urls.present? && product.image_urls.any?
            Rails.logger.info "Attempting URL-based image caching for product #{product.id} (#{product.image_urls.size} URLs)"

            if cache_images_from_urls(product)
              Rails.logger.info "Successfully cached images from URLs for product #{product.id}"
              success_count += 1
              processed = true
            else
              Rails.logger.error "Failed to cache images from URLs for product #{product.id}"
            end
          else
            Rails.logger.warn "Product #{product.id} has no eBay listing with images and no image URLs available"
          end
        end

        # If still not processed, count as failed
        if !processed
          failed_count += 1
          Rails.logger.error "Failed to process images for product #{product.id} - no viable image source found"
        end

      rescue => e
        failed_count += 1
        Rails.logger.error "Exception processing product #{product.id}: #{e.class} - #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
      end
    end

    Rails.logger.info "=== BATCH IMAGE MIGRATION SUMMARY ==="
    Rails.logger.info "Total products: #{products.size}"
    Rails.logger.info "Successfully processed: #{success_count}"
    Rails.logger.info "Skipped (already had images): #{skipped_count}"
    Rails.logger.info "Failed: #{failed_count}"
    Rails.logger.info "=== END BATCH SUMMARY ==="

    # If there are failures, we might want to retry later
    if failed_count > 0
      Rails.logger.warn "#{failed_count} products failed image migration. Consider retrying later when eBay images are downloaded."
    end
  end

  private

  def copy_images_from_ebay_listing(product, ebay_listing)
    image_count = 0
    failed_count = 0

    begin
      Rails.logger.info "Attempting to copy #{ebay_listing.images.count} images from eBay listing #{ebay_listing.id} to product #{product.id}"

      ebay_listing.images.each_with_index do |image, index|
        begin
          # Verify the blob exists before trying to attach
          unless image.blob.present?
            Rails.logger.error "Image #{index + 1} from eBay listing #{ebay_listing.id} has no blob - skipping"
            failed_count += 1
            next
          end

          # Try to attach the image blob
          product.images.attach(image.blob)
          image_count += 1
          Rails.logger.debug "Successfully attached image #{index + 1}/#{ebay_listing.images.count} to product #{product.id}"

        rescue ActiveStorage::FileNotFoundError => e
          Rails.logger.error "Image file not found for image #{index + 1} from eBay listing #{ebay_listing.id}: #{e.message}"
          failed_count += 1
        rescue => e
          Rails.logger.error "Failed to copy image #{index + 1} (ID: #{image.id}) from eBay listing #{ebay_listing.id} to product #{product.id}: #{e.class} - #{e.message}"
          failed_count += 1
        end
      end

      if image_count > 0
        # Update timestamp
        product.update_columns(images_last_synced_at: Time.current)

        if failed_count > 0
          Rails.logger.warn "Partially successful: copied #{image_count}/#{ebay_listing.images.count} images to product #{product.id} (#{failed_count} failed)"
        else
          Rails.logger.info "Successfully copied all #{image_count} images from eBay listing #{ebay_listing.id} to product #{product.id}"
        end
        true
      else
        Rails.logger.error "Failed to copy any images from eBay listing #{ebay_listing.id} to product #{product.id} (#{failed_count} failures out of #{ebay_listing.images.count} images)"
        false
      end
    rescue => e
      Rails.logger.error "Critical error copying images from eBay listing #{ebay_listing.id} to product #{product.id}: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      false
    end
  end

  def cache_images_from_urls(product)
    return false if product.image_urls.blank?

    cached_count = 0

    begin
      product.image_urls.each_with_index do |url, index|
        begin
          # Skip if URL is blank or malformed
          next if url.blank? || !url.match?(/\Ahttps?:\/\//)

          # Use Down for robust downloads with timeout
          temp_file = Down.download(url,
            max_size: 10 * 1024 * 1024,  # 10MB limit
            open_timeout: 30,             # 30 second timeout
            read_timeout: 60              # 60 second read timeout
          )

          product.images.attach(
            io: temp_file,
            filename: "product_image_#{product.id}_#{index}.jpg",
            content_type: temp_file.content_type || "image/jpeg"
          )

          cached_count += 1
          Rails.logger.debug "Successfully cached image #{index + 1}/#{product.image_urls.size} for product #{product.id}"

        rescue Down::Error => e
          Rails.logger.error "Download failed for image #{index + 1} (#{url}) for product #{product.id}: #{e.message}"
        rescue => e
          Rails.logger.error "Failed to cache image #{index + 1} (#{url}) for product #{product.id}: #{e.message}"
        ensure
          temp_file&.close
          temp_file&.unlink
        end
      end

      if cached_count > 0
        product.update_columns(images_last_synced_at: Time.current)
        Rails.logger.info "Successfully cached #{cached_count}/#{product.image_urls.size} images for product #{product.id}"
        true
      else
        Rails.logger.warn "No images were successfully cached for product #{product.id}"
        false
      end

    rescue => e
      Rails.logger.error "Error caching images from URLs for product #{product.id}: #{e.message}"
      false
    end
  end
end
