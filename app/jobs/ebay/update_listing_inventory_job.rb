module Ebay
  class UpdateListingInventoryJob < ApplicationJob
    queue_as :default

    def perform(shop_id, ebay_listing_id, kuralis_product_id)
      shop = Shop.find(shop_id)
      ebay_listing = shop.shopify_ebay_account.ebay_listings.find(ebay_listing_id)
      kuralis_product = shop.kuralis_products.find(kuralis_product_id)

      # Use the InventoryService to handle the update/end logic
      # TODO: We need to pass in the inventory_only flag to the InventoryService
      inventory_service = Ebay::InventoryService.new(ebay_listing, kuralis_product)
      result = inventory_service.update_inventory

      if result
        Rails.logger.info "Successfully processed eBay listing #{ebay_listing.ebay_item_id} update"
      else
        Rails.logger.error "Failed to process eBay listing #{ebay_listing.ebay_item_id} update"
      end
    end
  end
end
