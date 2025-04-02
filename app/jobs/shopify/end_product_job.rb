module Shopify
  class EndProductJob < ApplicationJob
    queue_as :shopify

    def perform(shop_id, shopify_product_id)
      shopify_product = ShopifyProduct.find(shopify_product_id)

      service = Shopify::EndProductService.new(shopify_product)
      result = service.end_product

      if result
        Rails.logger.info "Successfully ended Shopify product #{shopify_product.shopify_product_id}"
      else
        Rails.logger.error "Failed to end Shopify product #{shopify_product.shopify_product_id}"
      end
    end
  end
end
