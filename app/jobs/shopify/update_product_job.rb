module Shopify
  class UpdateProductJob < ApplicationJob
    queue_as :default

    def perform(shop_id, shopify_product_id, kuralis_product_id)
      shop = Shop.find(shop_id)
      shopify_product = shop.shopify_products.find(shopify_product_id)
      kuralis_product = shop.kuralis_products.find(kuralis_product_id)

      # Use the InventoryService to handle the update/end logic
      inventory_service = Shopify::InventoryService.new(shopify_product, kuralis_product)
      result = inventory_service.update_inventory

      if result
        Rails.logger.info "Successfully processed Shopify product #{shopify_product.id} update"
      else
        Rails.logger.error "Failed to process Shopify product #{shopify_product.id} update"
      end
    end
  end
end
