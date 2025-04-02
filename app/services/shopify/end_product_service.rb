module Shopify
  class EndProductService
    attr_reader :shopify_product, :shop

    def initialize(shopify_product)
      @shopify_product = shopify_product
      @shop = @shopify_product.shop
      @client = ShopifyAPI::Clients::Graphql::Admin.new(session: @shop.shopify_session)
    end

    def end_product
      if @shop.shopify_archive_products?
        archive_product
      else
        delete_product
      end
    end

    private

    def archive_product
      result = @client.query(
        query: end_product_mutation,
        variables: {
          input: {
            id: @shopify_product.gid,
            status: "ARCHIVED"
          }
        }
      )

      if result.body["data"] && result.body["data"]["productUpdate"] && result.body["data"]["productUpdate"]["product"]
        Rails.logger.info "Successfully archived Shopify product #{@shopify_product.shopify_product_id}"
        @shopify_product.update(status: "archived", unpublished_at: Time.current)
        true
      else
        error_message = result.body["errors"] || result.body["data"]&.dig("productUpdate", "userErrors")
        Rails.logger.error "Failed to archive Shopify product: #{error_message}"
        false
      end
    rescue => e
      Rails.logger.error "Error archiving Shopify product: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      false
    end

    def delete_product
      result = @client.query(
        query: delete_product_mutation,
        variables: {
          input: {
            id: @shopify_product.gid
          }
        }
      )

      if result.body["data"] && result.body["data"]["productDelete"] && result.body["data"]["productDelete"]["deletedProductId"]
        Rails.logger.info "Successfully deleted Shopify product #{@shopify_product.shopify_product_id}"
        @shopify_product.destroy!
        true
      else
        error_message = result.body["errors"] || result.body["data"]&.dig("productDelete", "userErrors")
        Rails.logger.error "Failed to delete Shopify product: #{error_message}"
        false
      end
    rescue => e
      Rails.logger.error "Error deleting Shopify product: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      false
    end

    def end_product_mutation
      <<~GQL
        mutation productUpdate($input: ProductInput!) {
          productUpdate(input: $input) {
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

    def delete_product_mutation
      <<~GQL
        mutation productDelete($input: ProductDeleteInput!) {
          productDelete(input: $input) {
            deletedProductId
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
