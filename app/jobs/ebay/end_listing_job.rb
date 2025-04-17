module Ebay
  class EndListingJob < ApplicationJob
    queue_as :ebay

    def perform(shop_id, ebay_listing_id, reason = "NotAvailable")
      shop = Shop.find(shop_id)
      ebay_listing = shop.shopify_ebay_account.ebay_listings.find(ebay_listing_id)

      service = Ebay::EndListingService.new(ebay_listing)
      result = service.end_listing(reason)

      if result
        Rails.logger.info "Successfully ended eBay listing #{ebay_listing.ebay_item_id}"
      else
        Rails.logger.error "Failed to end eBay listing #{ebay_listing.ebay_item_id}"
      end
    end
  end
end
