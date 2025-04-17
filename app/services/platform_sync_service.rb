class PlatformSyncService
  # Sync a KuralisProduct with all connected platforms
  def self.sync_product(kuralis_product)
    # Sync with Shopify if connected
    if kuralis_product.shopify_product.present?
      Shopify::UpdateProductJob.perform_later(
        kuralis_product.shop.id,
        kuralis_product.shopify_product.id,
        kuralis_product.id
      )
    end

    # Sync with eBay if connected
    if kuralis_product.ebay_listing.present?
      Ebay::UpdateListingJob.perform_later(
        kuralis_product.shop.id,
        kuralis_product.ebay_listing.id,
        kuralis_product.id
      )
    end
  end
end
