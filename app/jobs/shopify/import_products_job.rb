module Shopify
  class ImportProductsJob < ApplicationJob
    queue_as :default

    def perform(shop_id, last_sync_time = nil)
      shop = Shop.find(shop_id)
      client = ShopifyAPI::Clients::Graphql::Admin.new(session: shop.shopify_session)

      begin
        # Track existing products before import
        existing_product_ids = shop.shopify_products.pluck(:shopify_product_id)
        processed_product_ids = []
        after_cursor = nil

        loop do
          response = client.query(
            query: products_query,
            variables: {
              first: 10,
              after: after_cursor,
              query: nil
            }
          )

          products = response.body["data"]["products"]["edges"]
          processed_product_ids += process_products(products, shop)

          page_info = response.body["data"]["products"]["pageInfo"]

          if page_info["hasNextPage"]
            after_cursor = response.body["data"]["products"]["edges"].last["cursor"]
          else
            break
          end
        end

        # Handle deletions - mark products as inactive if they no longer exist in Shopify
        deleted_product_ids = existing_product_ids - processed_product_ids
        if deleted_product_ids.any?
          shop.shopify_products
              .where(shopify_product_id: deleted_product_ids)
              .update_all(
                status: "deleted",
                last_synced_at: Time.current
              )

          Rails.logger.info "Marked #{deleted_product_ids.size} products as deleted"
        end

        Rails.logger.info "Completed Shopify products import for shop #{shop.id}"
      rescue => e
        Rails.logger.error "Error importing Shopify products: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
      end
    end

    private

    def process_products(products, shop)
      processed_ids = []

      products.each do |edge|
        begin
          product = edge["node"]
          variant = product["variants"]["edges"].first["node"]

          product_id = extract_id_from_gid(product["id"])
          processed_ids << product_id

          variant_id = extract_id_from_gid(variant["id"])
          image_urls = product["images"]["edges"].map { |img| img["node"]["url"] }

          shopify_product = shop.shopify_products.find_or_initialize_by(
            shopify_product_id: product_id
          )

          shopify_product.assign_attributes({
            shopify_variant_id: variant_id,
            title: product["title"],
            description: product["description"],
            price: variant["price"],
            quantity: variant["inventoryQuantity"],
            sku: variant["sku"],
            status: product["status"].downcase,
            published: product["publishedAt"].present?,
            handle: product["handle"],
            product_type: product["productType"],
            vendor: product["vendor"],
            tags: product["tags"],
            options: product["options"]&.map { |opt| { name: opt["name"], values: opt["values"] } },
            image_urls: image_urls,
            last_synced_at: Time.current
          })

          if shopify_product.changed?
            Rails.logger.info "Changes detected for product #{product_id}: #{shopify_product.changes.inspect}"
            if shopify_product.save
              Rails.logger.info "#{shopify_product.new_record? ? 'Created' : 'Updated'} product #{product_id}"
              shopify_product.sync_images
            else
              Rails.logger.error "Failed to save product #{product_id}: #{shopify_product.errors.full_messages.join(', ')}"
            end
          else
            shopify_product.sync_images if shopify_product.needs_image_sync?
            Rails.logger.info "No changes detected for product #{product_id}"
          end
        rescue => e
          Rails.logger.error "Error processing product: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
        end
      end

      processed_ids
    end

    def products_query
      <<~GQL
        query($first: Int!, $after: String, $query: String) {
          products(first: $first, after: $after, query: $query) {
            edges {
              cursor
              node {
                id
                title
                description
                handle
                productType
                vendor
                tags
                status
                publishedAt
                options {
                  name
                  values
                }
                variants(first: 1) {
                  edges {
                    node {
                      id
                      price
                      inventoryQuantity
                      sku
                    }
                  }
                }
                images(first: 10) {
                  edges {
                    node {
                      url
                    }
                  }
                }
              }
            }
            pageInfo {
              hasNextPage
              endCursor
            }
          }
        }
      GQL
    end

    def extract_id_from_gid(gid)
      return nil if gid.blank?

      # Extract the numeric ID from formats like "gid://shopify/Product/12345"
      gid.split("/").last
    rescue
      Rails.logger.error "Failed to extract ID from GID: #{gid}"
      nil
    end
  end
end
