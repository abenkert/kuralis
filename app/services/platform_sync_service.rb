class PlatformSyncService
  # Sync a KuralisProduct with all connected platforms
  #
  # @param kuralis_product [KuralisProduct] The product to sync
  # @param options [Hash] Optional parameters
  # @option options [String] :skip_platform Platform to skip updating (e.g., "shopify", "ebay")
  # @option options [Boolean] :inventory_only Whether to only sync inventory, not other fields
  def self.sync_product(kuralis_product, options = {})
    # Extract options
    skip_platform = options[:skip_platform]&.downcase

    # Sync with Shopify if connected and not skipped
    if kuralis_product.shopify_product.present? && skip_platform != "shopify"
      Shopify::UpdateProductInventoryJob.perform_later(
        kuralis_product.shop.id,
        kuralis_product.shopify_product.id,
        kuralis_product.id
      )
    end

    # Sync with eBay if connected and not skipped
    if kuralis_product.ebay_listing.present? && skip_platform != "ebay"
      Ebay::UpdateListingInventoryJob.perform_later(
        kuralis_product.shop.id,
        kuralis_product.ebay_listing.id,
        kuralis_product.id
      )
    end
  end
end
