module Shopify
  class InventoryService
    attr_reader :shopify_product, :product, :shop

    def initialize(shopify_product, kuralis_product)
      @shopify_product = shopify_product
      @product = kuralis_product
      @shop = @product.shop
      @client = ShopifyAPI::Clients::Graphql::Admin.new(session: @shop.shopify_session)
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
      result = @client.query(
        query: update_product_mutation,
        variables: {
          input: {
            id: @shopify_product.gid,
            title: @product.title,
            descriptionHtml: @product.description.to_s,
            status: "ACTIVE"
          },
          inventoryLevels: [
            {
              inventoryItemId: @shopify_product.variant_gid,
              locationId: @shop.default_location_id,
              available: @product.base_quantity
            }
          ],
          variantInput: {
            id: @shopify_product.variant_gid,
            price: @product.base_price.to_s
          }
        }
      )

      if result.body["data"] && result.body["data"]["productUpdate"] && result.body["data"]["productUpdate"]["product"]
        @shopify_product.update(last_updated_at: Time.current)
        Rails.logger.info "Updated Shopify product #{@shopify_product.shopify_product_id} with latest information"
        true
      else
        error_message = result.body["errors"] || result.body["data"]&.dig("productUpdate", "userErrors")
        Rails.logger.error "Failed to update Shopify product: #{error_message}"
        false
      end
    rescue => e
      Rails.logger.error "Failed to update Shopify product: #{e.message}"
      false
    end

    def disable_product
      # For Shopify, we'll use the EndProductService to handle unpublishing
      end_service = Shopify::EndProductService.new(@shopify_product)
      end_service.end_product
    end

    private

    def update_product_mutation
      <<~GQL
        mutation productUpdate($input: ProductInput!, $inventoryLevels: [InventoryLevelInput!]!, $variantInput: ProductVariantInput!) {
          productUpdate(input: $input) {
            product {
              id
              title
              status
            }
            userErrors {
              field
              message
            }
          }
          productVariantUpdate(input: $variantInput) {
            productVariant {
              id
              price
            }
            userErrors {
              field
              message
            }
          }
          inventoryBulkAdjust(inventoryLevelInput: $inventoryLevels) {
            inventoryLevels {
              available
            }
            userErrors {
              field
              message
            }
          }
        }
      GQL
    end
  end
end
