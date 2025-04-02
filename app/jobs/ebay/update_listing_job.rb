module Ebay
  class UpdateListingJob < ApplicationJob
    queue_as :default

    def perform(ebay_listing, kuralis_product)
      # Update the eBay listing with the current inventory
      # Your eBay API update code here

      Rails.logger.info "Updated eBay listing #{ebay_listing.ebay_item_id} with quantity #{kuralis_product.quantity}"
    end
  end
end
