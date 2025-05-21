class MigrateEbayListingsJob < ApplicationJob
  ############################################################
  # This job is used to migrate eBay listings to KuralisProducts
  ############################################################
  queue_as :default

  # Configure batch size for processing
  BATCH_SIZE = 100

  def perform(shop_id, listing_ids)
    shop = Shop.find(shop_id)
    shopify_ebay_account = shop.shopify_ebay_account

    # Early return if nothing to process
    return if listing_ids.blank?

    # Prefetch all listings in one query to avoid N+1 queries
    listings_to_process = shopify_ebay_account.ebay_listings
                            .includes(:kuralis_product) # eager load associations
                            .where(id: listing_ids)
                            .to_a

    # Skip listings that already have a KuralisProduct
    listings_to_process.reject! { |listing| listing.kuralis_product.present? }

    # Prefetch necessary mappings to avoid repeated lookups
    shipping_profile_weights = shopify_ebay_account.shipping_profile_weights || {}
    category_tag_mappings = shopify_ebay_account.category_tag_mappings || {}

    # Process in batches to reduce memory usage and improve DB performance
    listings_to_process.each_slice(BATCH_SIZE) do |batch|
      # Prepare bulk insert data
      kuralis_products_data = []

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
          Rails.logger.error "Failed to prepare data for eBay listing #{listing.id}: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
        end
      end

      if kuralis_products_data.any?
        # Create all products in a single transaction
        KuralisProduct.transaction do
          new_products = KuralisProduct.insert_all!(
            kuralis_products_data,
            returning: %w[id ebay_listing_id image_urls]
          )

          # Batch image caching instead of creating a job for each product
          product_ids_for_image_caching = new_products
            .select { |p| p["image_urls"].present? }
            .map { |p| p["id"] }

          # Process images in batches of 50
          product_ids_for_image_caching.each_slice(50) do |batch_ids|
            BatchCacheKuralisProductImagesJob.perform_later(shop.id, batch_ids)
          end

          Rails.logger.info "Successfully migrated #{new_products.count} eBay listings in batch"
          Rails.logger.info "Scheduled #{product_ids_for_image_caching.size} products for image caching in batches"
        end
      end
    end
  end

  private

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
