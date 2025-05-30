class FixMissingImagesJob < ApplicationJob
  queue_as :images

  def perform(shop_id, limit: 100)
    shop = Shop.find_by(id: shop_id)
    return unless shop

    Rails.logger.info "=== STARTING MISSING IMAGES FIX JOB ==="

    # Find products without images
    products_without_images = shop.kuralis_products
                                  .left_joins(:images_attachments)
                                  .where(active_storage_attachments: { id: nil })
                                  .where(source_platform: "ebay") # Focus on eBay-sourced products
                                  .limit(limit)
                                  .includes(:ebay_listing)

    total_count = products_without_images.count
    Rails.logger.info "Found #{total_count} products without images to process"

    return if total_count == 0

    success_count = 0
    failed_count = 0
    no_source_count = 0

    products_without_images.find_each do |product|
      begin
        Rails.logger.info "Processing product #{product.id}: #{product.title}"

        processed = false

        # Strategy 1: Try eBay listing images first
        if product.ebay_listing.present?
          ebay_listing = product.ebay_listing

          if ebay_listing.images.attached?
            Rails.logger.info "Found #{ebay_listing.images.count} images on eBay listing #{ebay_listing.id}"

            if copy_images_from_ebay_listing(product, ebay_listing)
              Rails.logger.info "✅ Successfully copied images from eBay listing to product #{product.id}"
              success_count += 1
              processed = true
            end
          else
            Rails.logger.info "eBay listing #{ebay_listing.id} has no attached images, checking if images need to be downloaded..."

            # Check if eBay listing has image URLs but no downloaded images
            if ebay_listing.image_urls.present?
              Rails.logger.info "eBay listing has #{ebay_listing.image_urls.size} image URLs, attempting to download them first"

              # Try to download images to the eBay listing
              if download_ebay_listing_images(ebay_listing)
                Rails.logger.info "Downloaded images to eBay listing, now copying to product"

                if copy_images_from_ebay_listing(product, ebay_listing)
                  Rails.logger.info "✅ Successfully downloaded and copied images to product #{product.id}"
                  success_count += 1
                  processed = true
                end
              end
            end
          end
        end

        # Strategy 2: Try product image URLs
        if !processed && product.image_urls.present?
          Rails.logger.info "Attempting to cache images from product image URLs (#{product.image_urls.size} URLs)"

          if cache_images_from_urls(product)
            Rails.logger.info "✅ Successfully cached images from URLs for product #{product.id}"
            success_count += 1
            processed = true
          end
        end

        # Log if no viable source found
        if !processed
          no_source_count += 1
          Rails.logger.warn "❌ No viable image source found for product #{product.id}"
        end

      rescue => e
        failed_count += 1
        Rails.logger.error "💥 Exception processing product #{product.id}: #{e.class} - #{e.message}"
      end
    end

    Rails.logger.info "=== MISSING IMAGES FIX SUMMARY ==="
    Rails.logger.info "Total processed: #{total_count}"
    Rails.logger.info "✅ Successfully fixed: #{success_count}"
    Rails.logger.info "❌ Failed with errors: #{failed_count}"
    Rails.logger.info "⚠️ No image source available: #{no_source_count}"
    Rails.logger.info "=== END FIX SUMMARY ==="

    # Return summary for programmatic use
    {
      total: total_count,
      success: success_count,
      failed: failed_count,
      no_source: no_source_count
    }
  end

  private

  def copy_images_from_ebay_listing(product, ebay_listing)
    return false unless ebay_listing.images.attached?

    copied_count = 0
    failed_count = 0

    Rails.logger.info "Attempting to copy #{ebay_listing.images.count} images from eBay listing #{ebay_listing.id} to product #{product.id}"

    ebay_listing.images.each_with_index do |image, index|
      begin
        # Verify the blob exists before trying to attach
        unless image.blob.present?
          Rails.logger.error "Image #{index + 1} from eBay listing #{ebay_listing.id} has no blob - skipping"
          failed_count += 1
          next
        end

        # Attach the image blob without triggering validations
        product.images.attach(image.blob)
        copied_count += 1
        Rails.logger.debug "Successfully attached image #{index + 1}/#{ebay_listing.images.count} to product #{product.id}"

      rescue ActiveStorage::FileNotFoundError => e
        Rails.logger.error "Image file not found for image #{index + 1} from eBay listing #{ebay_listing.id}: #{e.message}"
        failed_count += 1
      rescue => e
        Rails.logger.error "Failed to copy image #{index + 1} (ID: #{image.id}) from eBay listing #{ebay_listing.id} to product #{product.id}: #{e.class} - #{e.message}"
        failed_count += 1
      end
    end

    if copied_count > 0
      # Use update_columns to bypass validations and only update the timestamp
      # This prevents validation failures (like weight_oz) from rolling back image attachments
      product.update_columns(images_last_synced_at: Time.current)

      # Force reload to ensure we see the attached images
      product.reload

      if failed_count > 0
        Rails.logger.warn "Partially successful: copied #{copied_count}/#{ebay_listing.images.count} images to product #{product.id} (#{failed_count} failed)"
      else
        Rails.logger.info "Successfully copied all #{copied_count} images from eBay listing #{ebay_listing.id} to product #{product.id}"
      end
      true
    else
      Rails.logger.error "Failed to copy any images from eBay listing #{ebay_listing.id} to product #{product.id} (#{failed_count} failures out of #{ebay_listing.images.count} images)"
      false
    end
  end

  def download_ebay_listing_images(ebay_listing)
    return false if ebay_listing.image_urls.blank?

    downloaded_count = 0

    ebay_listing.image_urls.each_with_index do |url, index|
      begin
        next if url.blank? || !url.match?(/\Ahttps?:\/\//)

        temp_file = Down.download(url,
          max_size: 10 * 1024 * 1024,
          open_timeout: 30,
          read_timeout: 60
        )

        ebay_listing.images.attach(
          io: temp_file,
          filename: "ebay_image_#{ebay_listing.ebay_item_id}_#{index}.jpg",
          content_type: temp_file.content_type || "image/jpeg"
        )

        downloaded_count += 1

      rescue Down::Error => e
        Rails.logger.error "Download failed for eBay image #{index + 1} (#{url}): #{e.message}"
      rescue => e
        Rails.logger.error "Failed to download eBay image #{index + 1} (#{url}): #{e.message}"
      ensure
        temp_file&.close
        temp_file&.unlink
      end
    end

    if downloaded_count > 0
      Rails.logger.info "Downloaded #{downloaded_count} images to eBay listing #{ebay_listing.id}"
      return true
    end

    false
  end

  def cache_images_from_urls(product)
    return false if product.image_urls.blank?

    cached_count = 0

    product.image_urls.each_with_index do |url, index|
      begin
        next if url.blank? || !url.match?(/\Ahttps?:\/\//)

        temp_file = Down.download(url,
          max_size: 10 * 1024 * 1024,
          open_timeout: 30,
          read_timeout: 60
        )

        product.images.attach(
          io: temp_file,
          filename: "product_image_#{product.id}_#{index}.jpg",
          content_type: temp_file.content_type || "image/jpeg"
        )

        cached_count += 1

      rescue Down::Error => e
        Rails.logger.error "Download failed for product image #{index + 1} (#{url}): #{e.message}"
      rescue => e
        Rails.logger.error "Failed to cache product image #{index + 1} (#{url}): #{e.message}"
      ensure
        temp_file&.close
        temp_file&.unlink
      end
    end

    if cached_count > 0
      product.update_columns(images_last_synced_at: Time.current)
      Rails.logger.info "Cached #{cached_count} images for product #{product.id}"
      return true
    end

    false
  end

  # Class method to get count of products missing images
  def self.missing_images_count(shop)
    shop.kuralis_products
        .left_joins(:images_attachments)
        .where(active_storage_attachments: { id: nil })
        .where(source_platform: "ebay")
        .count
  end

  # Class method to run the fix for a specific shop
  def self.fix_for_shop(shop, limit: 100)
    perform_later(shop.id, limit: limit)
  end
end
