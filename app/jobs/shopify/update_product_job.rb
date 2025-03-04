module Shopify
  class UpdateProductJob < ApplicationJob
    queue_as :default
    
    def perform(shopify_product_id)
      shopify_product = ShopifyProduct.find(shopify_product_id)
      kuralis_product = shopify_product.kuralis_product
      
      # Update the Shopify product with the current inventory
      # Your Shopify API update code here
      
      Rails.logger.info "Updated Shopify product #{shopify_product.shopify_id} with quantity #{kuralis_product.quantity}"
    end
  end
end 