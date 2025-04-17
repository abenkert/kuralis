class CacheEbayImagesJob < ApplicationJob
  queue_as :images
  include JobTrackable

  # Limit concurrent downloads to avoid overloading the server
  # throttle threshold: 5, key: -> { "ebay_image_cache" }

  # Process in batches of 10 to avoid memory issues
  BATCH_SIZE = 10

  def perform(account_id, listing_ids)
    @job_run = JobRun.find_by(job_id: job_id)

    # Early return if no listings to process
    if listing_ids.blank?
      update_job_status(message: "No listings to process")
      return
    end

    update_job_status(
      total: listing_ids.size,
      processed: 0,
      message: "Starting image caching for #{listing_ids.size} listings"
    )

    # Find the account
    account = ShopifyEbayAccount.find_by(id: account_id)
    unless account
      update_job_status(message: "Account not found")
      return
    end

    # Process listings in batches to manage memory usage
    listing_ids.each_slice(BATCH_SIZE).with_index do |batch_ids, batch_index|
      # Fetch the listings in this batch
      listings = account.ebay_listings.where(id: batch_ids)

      listings.each_with_index do |listing, index|
        begin
          cache_images_for_listing(listing)
        rescue => e
          Rails.logger.error("Error caching images for listing #{listing.id}: #{e.message}")
        end

        # Update progress
        overall_index = (batch_index * BATCH_SIZE) + index + 1
        update_job_status(
          processed: overall_index,
          message: "Processed #{overall_index} of #{listing_ids.size} listings"
        )
      end
    end

    update_job_status(message: "Image caching completed")
  end

  private

  def update_job_status(total: nil, processed: nil, message: nil)
    return unless @job_run

    progress_data = @job_run.progress_data || {}
    progress_data[:total] = total if total
    progress_data[:processed] = processed if processed
    progress_data[:message] = message if message
    progress_data[:percent] = ((progress_data[:processed].to_f / progress_data[:total]) * 100).round(2) if progress_data[:total].to_i > 0

    @job_run.update(progress_data: progress_data)
  end

  def cache_images_for_listing(listing)
    return if listing.images.attached? || listing.image_urls.blank?

    # Download and attach each image
    listing.image_urls.each_with_index do |url, index|
      begin
        # Skip if URL is blank or malformed
        next if url.blank? || !url.match?(/\Ahttps?:\/\//)

        # Use Down for robust downloads
        temp_file = Down.download(url, max_size: 10 * 1024 * 1024)

        listing.images.attach(
          io: temp_file,
          filename: "ebay_image_#{listing.ebay_item_id}_#{index}.jpg",
          content_type: temp_file.content_type || "image/jpeg"
        )
      rescue Down::Error => e
        Rails.logger.error("Failed to download image from #{url}: #{e.message}")
      rescue => e
        Rails.logger.error("Failed to cache image from #{url}: #{e.message}")
      ensure
        temp_file&.close
        temp_file&.unlink
      end
    end
  end
end
