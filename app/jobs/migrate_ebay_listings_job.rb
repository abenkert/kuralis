class MigrateEbayListingsJob < ApplicationJob
  ############################################################
  # This job is used to migrate eBay listings to KuralisProducts
  ############################################################
  include JobTrackable
  queue_as :default

  # Configure batch size for processing
  BATCH_SIZE = 100

  def perform(shop_id, listing_ids)
    @job_run = JobRun.find_by(job_id: job_id)

    shop = Shop.find(shop_id)
    shopify_ebay_account = shop.shopify_ebay_account

    # Early return if nothing to process
    if listing_ids.blank?
      update_job_status(message: "No listings to process")
      return
    end

    Rails.logger.info "=== STARTING EBAY LISTINGS MIGRATION ==="
    Rails.logger.info "Processing #{listing_ids.size} listings for shop #{shop.shopify_domain}"

    update_job_status(
      total: listing_ids.size,
      processed: 0,
      message: "Starting migration of #{listing_ids.size} eBay listings"
    )

    # Prefetch all listings in one query to avoid N+1 queries
    listings_to_process = shopify_ebay_account.ebay_listings
                            .includes(:kuralis_product) # eager load associations
                            .where(id: listing_ids)
                            .to_a

    # Skip listings that already have a KuralisProduct
    initial_count = listings_to_process.size
    listings_to_process.reject! { |listing| listing.kuralis_product.present? }
    skipped_count = initial_count - listings_to_process.size

    Rails.logger.info "Found #{listings_to_process.size} listings to migrate (#{skipped_count} already migrated)"

    if skipped_count > 0
      update_job_status(message: "Skipped #{skipped_count} already migrated listings")
    end

    # Prefetch necessary mappings to avoid repeated lookups
    shipping_profile_weights = shopify_ebay_account.shipping_profile_weights || {}
    category_tag_mappings = shopify_ebay_account.category_tag_mappings || {}

    total_success = 0
    total_failed = 0
    failed_listings = []

    # Process in batches to reduce memory usage and improve DB performance
    listings_to_process.each_slice(BATCH_SIZE).with_index do |batch, batch_index|
      Rails.logger.info "Processing batch #{batch_index + 1}/#{(listings_to_process.size.to_f / BATCH_SIZE).ceil} (#{batch.size} listings)"

      # Prepare bulk insert data
      kuralis_products_data = []
      batch_failed = []

      batch.each do |listing|
        begin
          # Get weight from shipping profile mapping (using preloaded data)
          weight_oz = get_weight_from_cached_mapping(
            shipping_profile_weights,
            listing.shipping_profile_id.to_s
          ) || 0

          # Get tags from store category mapping (using preloaded data)
          tags = get_tags_from_cached_mapping(
            category_tag_mappings,
            listing.store_category_id.to_s
          )

          # Prepare data for bulk creation
          kuralis_products_data << {
            shop_id: shop.id,
            title: listing.title,
            description: listing.description,
            base_price: listing.sale_price,
            base_quantity: listing.quantity,
            initial_quantity: listing.quantity,
            sku: nil, # We'll need to generate this
            brand: listing.item_specifics["Brand"],
            condition: listing.condition_description,
            location: listing.location,
            image_urls: listing.image_urls,
            images_last_synced_at: Time.current,
            product_attributes: listing.item_specifics,
            source_platform: "ebay",
            status: listing.active? ? "active" : "inactive",
            ebay_listing_id: listing.id,
            last_synced_at: Time.current,
            weight_oz: weight_oz,
            tags: tags,
            created_at: Time.current,
            updated_at: Time.current,
            imported_at: Time.current
          }
        rescue => e
          Rails.logger.error "Failed to prepare data for eBay listing #{listing.id} (#{listing.title}): #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          batch_failed << { listing_id: listing.id, title: listing.title, error: e.message }
        end
      end

      if kuralis_products_data.any?
        begin
          # Create all products in a single transaction
          KuralisProduct.transaction do
            new_products = KuralisProduct.insert_all!(
              kuralis_products_data,
              returning: %w[id ebay_listing_id image_urls]
            )

            batch_success_count = new_products.count
            total_success += batch_success_count

            Rails.logger.info "Successfully migrated #{batch_success_count} eBay listings in batch #{batch_index + 1}"

            # Batch image caching instead of creating a job for each product
            product_ids_for_image_caching = new_products
              .select { |p| p["image_urls"].present? }
              .map { |p| p["id"] }

            if product_ids_for_image_caching.any?
              # Process images in batches of 50
              product_ids_for_image_caching.each_slice(50) do |batch_ids|
                BatchCacheKuralisProductImagesJob.perform_later(shop.id, batch_ids)
              end

              Rails.logger.info "Scheduled #{product_ids_for_image_caching.size} products for image caching in batches"
            end
          end
        rescue => e
          Rails.logger.error "Failed to bulk insert batch #{batch_index + 1}: #{e.class} - #{e.message}"
          Rails.logger.error e.backtrace.join("\n")

          # Mark entire batch as failed
          batch.each do |listing|
            batch_failed << { listing_id: listing.id, title: listing.title, error: "Bulk insert failed: #{e.message}" }
          end
        end
      end

      # Track failed listings
      total_failed += batch_failed.size
      failed_listings.concat(batch_failed)

      # Update progress
      processed_so_far = total_success + total_failed
      update_job_status(
        processed: processed_so_far,
        message: "Processed #{processed_so_far}/#{listings_to_process.size} listings (#{total_success} successful, #{total_failed} failed)"
      )
    end

    # Final summary
    Rails.logger.info "=== MIGRATION COMPLETED ==="
    Rails.logger.info "Total listings processed: #{listings_to_process.size}"
    Rails.logger.info "Successfully migrated: #{total_success}"
    Rails.logger.info "Failed to migrate: #{total_failed}"

    if failed_listings.any?
      Rails.logger.error "Failed listings details:"
      failed_listings.each do |failure|
        Rails.logger.error "  - Listing ID #{failure[:listing_id]} (#{failure[:title]}): #{failure[:error]}"
      end
    end

    Rails.logger.info "=== END MIGRATION ==="

    # Send notification about completion
    create_completion_notification(shop, total_success, total_failed, failed_listings)

    # Update final job status
    update_job_status(
      processed: listings_to_process.size,
      message: "Migration completed: #{total_success} successful, #{total_failed} failed"
    )

  rescue => e
    Rails.logger.error "Critical error in MigrateEbayListingsJob: #{e.class} - #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    update_job_status(message: "Migration failed: #{e.message}")

    # Send error notification
    create_error_notification(shop, e.message)

    raise # Re-raise to mark job as failed
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

  def create_completion_notification(shop, success_count, failed_count, failed_listings)
    if failed_count == 0
      # All successful
      Notification.create!(
        shop_id: shop.id,
        title: "eBay Migration Completed Successfully",
        message: "Successfully migrated #{success_count} eBay listings to Kuralis products.",
        category: "ebay_migration"
      )
    else
      # Some failures
      message = "Migration completed with #{success_count} successful and #{failed_count} failed migrations."

      if failed_listings.size <= 5
        message += "\n\nFailed listings:\n"
        failed_listings.each do |failure|
          message += "• #{failure[:title]} (ID: #{failure[:listing_id]}): #{failure[:error]}\n"
        end
      else
        message += "\n\nFirst 5 failed listings:\n"
        failed_listings.first(5).each do |failure|
          message += "• #{failure[:title]} (ID: #{failure[:listing_id]}): #{failure[:error]}\n"
        end
        message += "\n... and #{failed_listings.size - 5} more. Check logs for details."
      end

      Notification.create!(
        shop_id: shop.id,
        title: "eBay Migration Completed with Errors",
        message: message,
        category: "ebay_migration"
      )
    end
  end

  def create_error_notification(shop, error_message)
    Notification.create!(
      shop_id: shop.id,
      title: "eBay Migration Failed",
      message: "Migration job failed with error: #{error_message}. Please check logs for details.",
      category: "ebay_migration"
    )
  end

  # Use cached weight mapping for performance
  def get_weight_from_cached_mapping(mapping, shipping_profile_id)
    return nil if shipping_profile_id.blank?

    weight_mapping = mapping[shipping_profile_id]
    weight_mapping.present? ? weight_mapping.to_d : nil
  end

  # Use cached tag mapping for performance
  def get_tags_from_cached_mapping(mapping, store_category_id)
    return [] if store_category_id.blank?

    tags_mapping = mapping[store_category_id]
    tags_mapping.present? ? Array(tags_mapping) : []
  end
end
