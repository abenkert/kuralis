module Shopify
  class UpdateProductJob < ApplicationJob
    queue_as :default

    def perform(shop_id, shopify_product, kuralis_product)
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
