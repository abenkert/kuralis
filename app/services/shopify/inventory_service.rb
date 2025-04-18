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

    def update_product
      # Update product details
      # product_updated = update_product_details

      # Update variant price
      # variant_updated = update_variant_price

      # Update inventory level separately
      inventory_updated = update_inventory_level

      if inventory_updated
        @shopify_product.update(
          price: @product.base_price,
          status: "active"
        )
        Rails.logger.info "Updated Shopify product #{@shopify_product.shopify_product_id} with latest information"
        true
      else
        Rails.logger.error "Failed to update inventory of Shopify product"
        false
      end
    rescue => e
      Rails.logger.error "Failed to update Shopify product: #{e.message}"
      false
    end

    # TODO: We need to move this to a different job for just updating details
    # def update_product_details
    #   result = @client.query(
    #     query: product_update_mutation,
    #     variables: {
    #       input: {
    #         id: @shopify_product.gid,
    #         title: @shopify_product.title,
    #         descriptionHtml: @product.description.to_s,
    #         status: "ACTIVE"
    #       }
    #     }
    #   )

    #   if result.body["data"] && result.body["data"]["productUpdate"] && result.body["data"]["productUpdate"]["product"]
    #     true
    #   else
    #     error_message = result.body["errors"] || result.body["data"]&.dig("productUpdate", "userErrors")
    #     Rails.logger.error "Failed to update Shopify product details: #{error_message}"
    #     false
    #   end
    # rescue => e
    #   Rails.logger.error "Failed to update Shopify product details: #{e.message}"
    #   false
    # end

    # def update_variant_price
    #   # Add debug logging
    #   Rails.logger.info "Updating variant with gid: #{@shopify_product.variant_gid}"

    #   # Get the first variant ID directly from the product
    #   variant_data = get_first_variant_id

    #   if variant_data.nil?
    #     Rails.logger.error "Could not find a valid variant ID for product #{@shopify_product.gid}"
    #     return false
    #   end

    #   Rails.logger.info "Using variant ID: #{variant_data[:variant_id]}"

    #   result = @client.query(
    #     query: variant_update_mutation,
    #     variables: {
    #         productId: @shopify_product.gid,
    #         variants: [
    #           {
    #             id: variant_data[:variant_id],
    #             price: @product.base_price.to_s
    #           }
    #         ]
    #       }
    #   )

    #   if result.body["data"] && result.body["data"]["productVariantsBulkUpdate"] && result.body["data"]["productVariantsBulkUpdate"]["productVariants"]
    #     true
    #   else
    #     error_message = result.body["errors"] || result.body["data"]&.dig("productVariantsBulkUpdate", "userErrors")
    #     Rails.logger.error "Failed to update Shopify variant price: #{error_message}"
    #     false
    #   end
    # rescue => e
    #   Rails.logger.error "Failed to update Shopify variant price: #{e.message}"
    #   false
    # end

    def update_inventory_level
      # Get the inventory item ID
      variant_data = get_first_variant_id

      if variant_data.nil? || variant_data[:inventory_item_id].nil?
        Rails.logger.error "Could not find a valid inventory item ID for product #{@shopify_product.gid}"
        return false
      end

      delta = @product.base_quantity - @shopify_product.quantity

      # Skip if there's no change needed
      if delta == 0
        Rails.logger.info "No inventory adjustment needed for product #{@shopify_product.shopify_product_id} (current: #{@shopify_product.quantity}, target: #{@product.base_quantity})"
        return true
      end

      Rails.logger.info "Adjusting inventory for product #{@shopify_product.shopify_product_id} by #{delta} (current: #{@shopify_product.quantity}, target: #{@product.base_quantity})"

      inventory_item_id = variant_data[:inventory_item_id]
      Rails.logger.info "Updating inventory for item ID: #{inventory_item_id}"

      result = @client.query(
        query: inventory_update_mutation,
        variables: {
          input: {
            reason: "other",
            name: "available",
            changes: [
              {
                inventoryItemId: inventory_item_id,
                locationId: @shop.default_location_id,
                delta: delta
              }
            ]
          }
        }
      )

      if result.body["data"] && result.body["data"]["inventoryAdjustQuantities"] &&
         !result.body["data"]["inventoryAdjustQuantities"]["userErrors"]&.any?
        Rails.logger.info "Successfully adjusted inventory by #{delta}"
        true
      else
        error_message = result.body["errors"] || result.body["data"]&.dig("inventoryAdjustQuantities", "userErrors")
        Rails.logger.error "Failed to update Shopify inventory: #{error_message}"
        false
      end
    rescue => e
      Rails.logger.error "Failed to update Shopify inventory: #{e.message}"
      false
    end

    def disable_product
      # For Shopify, we'll use the EndProductService to handle unpublishing
      end_service = Shopify::EndProductService.new(@shopify_product)
      end_service.end_product
    end

    private

    def product_update_mutation
      <<~GQL
        mutation productUpdate($input: ProductInput!) {
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
        }
      GQL
    end

    def variant_update_mutation
      <<~GQL
        mutation productVariantsBulkUpdate($productId: ID!, $variants: [ProductVariantsBulkInput!]!) {
          productVariantsBulkUpdate(productId: $productId, variants: $variants) {
            product {
              id
            }
            productVariants {
              id
              price
            }
            userErrors {
              field
              message
            }
          }
        }
      GQL
    end

    def inventory_update_mutation
      <<~GQL
        mutation inventoryAdjustQuantities($input: InventoryAdjustQuantitiesInput!) {
          inventoryAdjustQuantities(input: $input) {
            inventoryAdjustmentGroup {
              id
            }
            userErrors {
              field
              message
            }
          }
        }
      GQL
    end

    # Add this new private method to get the first variant ID
    def get_first_variant_id
      query = <<~GQL
        query {
          product(id: "#{@shopify_product.gid}") {
            variants(first: 1) {
              edges {
                node {
                  id
                  inventoryItem {
                    id
                  }
                }
              }
            }
          }
        }
      GQL

      result = @client.query(query: query)

      # Log the full response for debugging
      Rails.logger.debug "Variant query response: #{result.body.inspect}"

      if result.body["errors"]
        Rails.logger.error "GraphQL errors when fetching variant: #{result.body["errors"].inspect}"
        return nil
      end

      if result.body["data"] && result.body["data"]["product"] &&
         result.body["data"]["product"]["variants"] &&
         result.body["data"]["product"]["variants"]["edges"] &&
         !result.body["data"]["product"]["variants"]["edges"].empty? &&
         result.body["data"]["product"]["variants"]["edges"].first["node"]

        variant = result.body["data"]["product"]["variants"]["edges"].first["node"]
        variant_id = variant["id"]
        inventory_item_id = variant["inventoryItem"] ? variant["inventoryItem"]["id"] : nil

        Rails.logger.info "Successfully retrieved variant ID: #{variant_id}"
        Rails.logger.info "Associated inventory item ID: #{inventory_item_id}"

        {
          variant_id: variant_id,
          inventory_item_id: inventory_item_id
        }
      else
        Rails.logger.error "Product exists but no variants found or unexpected response structure: #{result.body.inspect}"
        nil
      end
    rescue => e
      Rails.logger.error "Error fetching variant ID: #{e.message}"
      nil
    end
  end
end
