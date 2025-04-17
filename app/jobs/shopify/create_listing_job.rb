module Shopify
  class CreateListingJob < ApplicationJob
    def perform(kuralis_product_id)
      product = KuralisProduct.find(kuralis_product_id)

      service = Shopify::ListingService.new(product)
      success = service.create_listing

      if success
        Rails.logger.info "Successfully created Shopify listing for product #{product.id}"
      else
        Rails.logger.error "Failed to create Shopify listing for product #{product.id}"
      end
    end
  end
end
