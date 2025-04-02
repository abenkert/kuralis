module Shopify
  class InventoryService
    attr_reader :shopify_product, :product, :shop

    def initialize(shopify_product, kuralis_product)
      @shopify_product = shopify_product
      @product = kuralis_product
      @shop = @product.shop
    end

    def update_inventory
      if @product.base_quantity <= 0 || @product.status != "active"
        disable_product
      else
        update_product
      end
    end

    private

    def update_product
      shopify_api.update_product(@shopify_product.shopify_id, product_data)
      @shopify_product.update(last_updated_at: Time.current)
      Rails.logger.info "Updated Shopify product #{@shopify_product.shopify_id} with latest information"
      true
    rescue => e
      Rails.logger.error "Failed to update Shopify product: #{e.message}"
      false
    end

    def disable_product
      # For Shopify, we'll unpublish the product instead of removing it completely
      data = product_data.merge(status: "draft")
      shopify_api.update_product(@shopify_product.shopify_id, data)
      @shopify_product.update(shopify_status: "unpublished", unpublished_at: Time.current)
      Rails.logger.info "Unpublished Shopify product #{@shopify_product.shopify_id}"
      true
    rescue => e
      Rails.logger.error "Failed to unpublish Shopify product: #{e.message}"
      false
    end

    def product_data
      {
        title: @product.title,
        body_html: @product.description.to_s,
        variants: [
          {
            id: @shopify_product.primary_variant_id,
            price: @product.base_price.to_s,
            inventory_quantity: @product.base_quantity,
            inventory_management: "shopify"
          }
        ],
        status: @product.status == "active" ? "active" : "draft"
      }
    end

    def shopify_api
      @shopify_api ||= ShopifyAPI::Client.new(
        shop: @shop.shopify_domain,
        access_token: @shop.shopify_token
      )
    end
  end
end
