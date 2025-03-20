module Ebay
  class CreateListingJob < ApplicationJob
    queue_as :ebay

    def perform(shop_id:, kuralis_product_id:)
      product = KuralisProduct.find(kuralis_product_id)

      service = EbayListingService.new(product)
      success = service.create_listing

      if success
        Rails.logger.info "Successfully created eBay listing for product #{product.id}"
      else
        Rails.logger.error "Failed to create eBay listing for product #{product.id}"
        raise StandardError, "Failed to create eBay listing"
      end
    end
  end
end
