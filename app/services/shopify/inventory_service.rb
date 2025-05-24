module Shopify
  class InventoryService
    attr_reader :shopify_product, :product, :shop
    class ShopifyUpdateError < StandardError; end

    def initialize(shopify_product, kuralis_product)
      @shopify_product = shopify_product
      @product = kuralis_product
      @shop = @product.shop
      @client = ShopifyAPI::Clients::Graphql::Admin.new(session: @shop.shopify_session)
    end

    def update_inventory
      Rails.logger.info "Updating Shopify inventory for product_id=#{@product.id}, quantity=#{@product.base_quantity}"

      # Handle different inventory scenarios
      if @product.base_quantity.zero?
        handle_zero_inventory
      else
        handle_inventory_update
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

    def handle_zero_inventory
      case @product.status
      when "completed"
        # Use EndProductService to respect shop's archiving preference
        handle_completed_product_with_zero_inventory
      when "inactive"
        # Set to draft but don't archive
        set_product_status("DRAFT")
      else
        # Just update inventory to 0 but keep active
        update_shopify_inventory_only
      end
    end

    def handle_inventory_update
      # Update both inventory and ensure product is active
      success = update_shopify_inventory_only

      if success && @product.status == "active"
        # Ensure product is published if it was previously archived
        set_product_status("ACTIVE")
      end

      success
    end

    def handle_completed_product_with_zero_inventory
      Rails.logger.info "Handling completed product with zero inventory: product_id=#{@shopify_product.shopify_product_id}"

      # First set inventory to 0
      inventory_success = update_shopify_inventory_only

      # Then archive or delete based on shop preference
      end_product_success = disable_product  # This calls EndProductService which respects shop settings

      if end_product_success
        action = @shop.shopify_archive_products? ? "archived" : "deleted"
        Rails.logger.info "Successfully #{action} Shopify product_id=#{@shopify_product.shopify_product_id} due to zero inventory"
      else
        action = @shop.shopify_archive_products? ? "archive" : "delete"
        Rails.logger.error "Failed to #{action} Shopify product_id=#{@shopify_product.shopify_product_id}"
      end

      inventory_success && end_product_success
    end

    def archive_product_on_shopify
      Rails.logger.info "Archiving Shopify product due to zero inventory"

      # First set inventory to 0
      inventory_success = update_shopify_inventory_only

      # Then archive the product
      archive_success = set_product_status("ARCHIVED")

      if archive_success
        Rails.logger.info "Successfully archived Shopify product_id=#{@shopify_product.shopify_product_id}"
      else
        Rails.logger.error "Failed to archive Shopify product_id=#{@shopify_product.shopify_product_id}"
      end

      inventory_success && archive_success
    end

    def update_shopify_inventory_only
      # Use the same logic as update_inventory_level but simplified
      variant_data = get_first_variant_id

      if variant_data.nil? || variant_data[:inventory_item_id].nil?
        Rails.logger.error "Could not find a valid inventory item ID for product #{@shopify_product.gid}"
        return false
      end

      delta = @product.base_quantity - @shopify_product.quantity

      # Skip if there's no change needed
      if delta == 0
        Rails.logger.info "No inventory adjustment needed for product #{@shopify_product.shopify_product_id}"
        return true
      end

      Rails.logger.info "Adjusting inventory for product #{@shopify_product.shopify_product_id} by #{delta}"

      begin
        response = @client.query(
          query: inventory_update_mutation,
          variables: {
            input: {
              reason: "other",
              name: "available",
              changes: [
                {
                  inventoryItemId: variant_data[:inventory_item_id],
                  locationId: @shop.default_location_id,
                  delta: delta
                }
              ]
            }
          }
        )

        if response.body["errors"]
          Rails.logger.error "Shopify inventory update error: #{response.body['errors']}"
          return false
        end

        if response.body["data"]["inventoryAdjustQuantities"]["userErrors"]&.any?
          errors = response.body["data"]["inventoryAdjustQuantities"]["userErrors"]
          Rails.logger.error "Shopify inventory update user errors: #{errors}"
          return false
        end

        Rails.logger.info "Successfully updated Shopify inventory to #{@product.base_quantity}"
        true

      rescue => e
        Rails.logger.error "Error updating Shopify inventory: #{e.message}"
        false
      end
    end

    def set_product_status(status)
      begin
        response = @client.query(
          query: product_status_mutation,
          variables: {
            productId: @shopify_product.gid,
            status: status
          }
        )

        if response.body["errors"]
          Rails.logger.error "Shopify product status update error: #{response.body['errors']}"
          return false
        end

        if response.body["data"]["productUpdate"]["userErrors"].any?
          errors = response.body["data"]["productUpdate"]["userErrors"]
          Rails.logger.error "Shopify product status update user errors: #{errors}"
          return false
        end

        Rails.logger.info "Successfully set Shopify product status to #{status}"
        true

      rescue => e
        Rails.logger.error "Error updating Shopify product status: #{e.message}"
        false
      end
    end

    def product_status_mutation
      <<~GQL
        mutation productUpdate($productId: ID!, $status: ProductStatus!) {
          productUpdate(
            input: {
              id: $productId
              status: $status
            }
          ) {
            product {
              id
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

    def primary_location_id
      # You'll need to get the primary location ID for your shop
      # This is typically cached or stored in your shop configuration
      @shop.primary_location_id || fetch_primary_location_id
    end

    def fetch_primary_location_id
      # Fetch the primary location from Shopify
      response = @client.query(
        query: locations_query
      )

      locations = response.body["data"]["locations"]["edges"]
      primary_location = locations.find { |edge| edge["node"]["isPrimary"] }

      if primary_location
        location_id = primary_location["node"]["id"].split("/").last
        # Cache this for future use
        @shop.update(primary_location_id: location_id) if @shop.respond_to?(:primary_location_id=)
        location_id
      else
        # Fallback to first location
        locations.first["node"]["id"].split("/").last if locations.any?
      end
    end

    def locations_query
      <<~GQL
        query {
          locations(first: 10) {
            edges {
              node {
                id
                name
                isPrimary
              }
            }
          }
        }
      GQL
    end
  end
end
