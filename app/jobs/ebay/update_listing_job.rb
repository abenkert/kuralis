module Ebay
  class UpdateListingJob < ApplicationJob
    queue_as :default

    def perform(shop_id, ebay_listing, kuralis_product)
      # Use the InventoryService to handle the update/end logic
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
