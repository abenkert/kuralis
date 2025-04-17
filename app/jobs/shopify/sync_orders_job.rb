module Shopify
  class SyncOrdersJob < ApplicationJob
    ##############################################################
    ############## Sync Orders from Shopify to Kuralis ###########
    ##############################################################
    # TODO: We have no approval currently to retrieve customer data from shopify so for now we wont have access to the customer info or shipping info.
    # TODO: We will need to add approval for this in the future.
    ##############################################################
    queue_as :default

    OLDER_ORDERS_CHECK_INTERVAL = 6.hours
    RECENT_WINDOW = 72.hours
    EXTENDED_WINDOW = 30.days

    def perform(shop_id = nil)
      if shop_id
        sync_shop(Shop.find(shop_id))
      else
        Shop.find_each do |shop|
          next unless shop.shopify_session # Skip shops without Shopify connection

          begin
            sync_shop(shop)
          rescue => e
            Rails.logger.error "Failed to sync Shopify orders for shop #{shop.id}: #{e.message}"
            Rails.logger.error e.backtrace.join("\n")
          end
        end
      end
    end

    private

    def sync_shop(shop)
      @shop = shop
      @client = ShopifyAPI::Clients::Graphql::Admin.new(session: @shop.shopify_session)

      # Always process recent orders
      process_recent_orders

      # Check older unfulfilled orders less frequently
      process_older_unfulfilled_orders if should_check_older_orders?
    end

    def process_recent_orders
      start_time = RECENT_WINDOW.ago.iso8601

      orders_response = fetch_orders(start_time)
      process_orders(orders_response)

      Rails.logger.info "Processed recent orders for shop #{@shop.id}"
    end

    def fetch_orders(start_time)
      after_cursor = nil
      all_orders = []

      loop do
        response = @client.query(
          query: orders_query,
          variables: {
            first: 50,
            after: after_cursor,
            query: "created_at:>='#{start_time}'"
          }
        )

        raise "Shopify API Error: #{response.body['errors']}" if response.body["errors"]

        orders = response.body["data"]["orders"]["edges"]
        break if orders.empty?

        all_orders += orders.map { |edge| edge["node"] }

        page_info = response.body["data"]["orders"]["pageInfo"]
        break unless page_info["hasNextPage"]
        after_cursor = orders.last["cursor"]
      end

      all_orders
    end

    def process_orders(orders)
      active_order_ids = []

      orders.each do |order_data|
        begin
          order = @shop.orders.find_or_initialize_by(
            platform: "shopify",
            platform_order_id: extract_id_from_gid(order_data["id"])
          )

          update_order_status(order, order_data)
        rescue => e
          Rails.logger.error "Failed to process order #{order_data['id']}: #{e.message}"
        end
      end
    end

    def update_order_status(order, order_data)
      order.assign_attributes({
        subtotal: order_data["subtotalPriceSet"]["shopMoney"]["amount"].to_f,
        total_price: order_data["totalPriceSet"]["shopMoney"]["amount"].to_f,
        shipping_cost: order_data["totalShippingPriceSet"]["shopMoney"]["amount"].to_f,
        fulfillment_status: order_data["displayFulfillmentStatus"]&.downcase,
        payment_status: order_data["displayFinancialStatus"]&.downcase,
        paid_at: order_data["processedAt"],
        shipping_address: nil,
        customer_name: nil,
        order_placed_at: order_data["createdAt"]
      })

      order.save!
      process_order_items(order, order_data["lineItems"]["edges"])
    end

    def process_order_items(order, line_items)
      line_items.each do |edge|
        item = edge["node"]
        order_item = order.order_items.find_or_initialize_by(
          platform: "shopify",
          platform_item_id: extract_id_from_gid(item["id"])
        )

        variant_id = extract_id_from_gid(item["variant"]["id"])
        kuralis_product = ShopifyProduct.find_by(shopify_variant_id: variant_id)&.kuralis_product

        if kuralis_product
          # Only adjust inventory if inventory sync is enabled and this is a new order
          # or an order that happened AFTER the product was imported
          should_adjust_inventory = @shop.inventory_sync? &&
                                   (
                                     # Check if this is a newly created order that we just added to our system
                                     order.created_at >= 10.minutes.ago ||
                                     # OR if it's a status update to an existing order we were already tracking
                                     order.updated_at != order.created_at ||
                                     # OR if the order was placed AFTER the product was imported into our system
                                     # This is critical to prevent double-counting historical orders
                                     (
                                       kuralis_product.imported_at.present? &&
                                       order.order_placed_at.present? &&
                                       order.order_placed_at > kuralis_product.imported_at
                                     )
                                   )

          if should_adjust_inventory
            if order.cancelled?
              InventoryService.release_inventory(
                kuralis_product: kuralis_product,
                quantity: item["quantity"],
                order_item: order_item
              )
            else
              InventoryService.allocate_inventory(
                kuralis_product: kuralis_product,
                quantity: item["quantity"],
                order_item: order_item
              )
            end
          else
            Rails.logger.info "Skipping inventory adjustment for historical Shopify order: #{order.platform_order_id}. Order date: #{order.order_placed_at}, Product import date: #{kuralis_product.imported_at}"
          end
        end

        order_item.update!(
          title: item["title"],
          quantity: item["quantity"],
          kuralis_product: kuralis_product
        )
      end
    end

    def extract_shipping_address(address)
      return {} unless address

      {
        name: address["name"],
        street1: address["address1"],
        street2: address["address2"],
        city: address["city"],
        state: address["province"],
        postal_code: address["zip"],
        country: address["countryCode"],
        phone: address["phone"]
      }
    end

    def extract_customer_name(customer)
      if customer
        "#{customer['firstName']} #{customer['lastName']}".strip
      else
        "Unknown Customer"
      end
    end

    def orders_query
      <<~GQL
        query($first: Int!, $after: String, $query: String) {
          orders(first: $first, after: $after, query: $query) {
            edges {
              cursor
              node {
                id
                createdAt
                processedAt
                cancelledAt
                displayFulfillmentStatus
                displayFinancialStatus
                subtotalPriceSet {
                  shopMoney {
                    amount
                  }
                }
                totalPriceSet {
                  shopMoney {
                    amount
                  }
                }
                totalShippingPriceSet {
                  shopMoney {
                    amount
                  }
                }
                lineItems(first: 50) {
                  edges {
                    node {
                      id
                      title
                      quantity
                      variant {
                        id
                      }
                    }
                  }
                }
              }
            }
            pageInfo {
              hasNextPage
            }
          }
        }
      GQL
    end

    def extract_id_from_gid(gid)
      return nil if gid.blank?
      gid.split("/").last
    rescue => e
      Rails.logger.error "Failed to extract ID from GID: #{gid}"
      nil
    end

    def should_check_older_orders?
      last_check = Rails.cache.read(older_orders_cache_key)
      last_check.nil? || last_check < OLDER_ORDERS_CHECK_INTERVAL.ago
    end

    def older_orders_cache_key
      "shopify_older_orders_last_check:#{@shop.id}"
    end

    def process_older_unfulfilled_orders
      unfulfilled_orders = @shop.orders
                               .where(platform: "shopify")
                               .where.not(status: [ "completed", "cancelled" ])
                               .where("created_at > ?", EXTENDED_WINDOW.ago)

      unfulfilled_orders.find_each do |order|
        update_single_order(order)
      end

      Rails.cache.write(older_orders_cache_key, Time.current, expires_in: OLDER_ORDERS_CHECK_INTERVAL)
      Rails.logger.info "Processed older unfulfilled orders for shop #{@shop.id}"
    end

    def update_single_order(order)
      response = @client.query(
        query: single_order_query,
        variables: { id: "gid://shopify/Order/#{order.platform_order_id}" }
      )

      if response.body["data"] && response.body["data"]["order"]
        order_data = response.body["data"]["order"]
        update_order_status(order, order_data)
      end
    rescue => e
      Rails.logger.error "Failed to update order #{order.platform_order_id}: #{e.message}"
    end

    def single_order_query
      <<~GQL
        query($id: ID!) {
          order(id: $id) {
            id
            createdAt
            processedAt
            displayFulfillmentStatus
            displayFinancialStatus
            subtotalPriceSet {
              shopMoney {
                amount
              }
            }
            totalPriceSet {
              shopMoney {
                amount
              }
            }
            totalShippingPriceSet {
              shopMoney {
                amount
              }
            }
            lineItems(first: 50) {
              edges {
                node {
                  id
                  title
                  quantity
                  variant {
                    id
                  }
                }
              }
            }
          }
        }
      GQL
    end
  end
end
