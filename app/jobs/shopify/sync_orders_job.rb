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
        sync_shop_with_coordination(Shop.find(shop_id))
      else
        Shop.find_each do |shop|
          next unless shop.shopify_session # Skip shops without Shopify connection

          begin
            sync_shop_with_coordination(shop)
          rescue JobCoordinationService::JobConflictError => e
            Rails.logger.warn "Skipping Shopify order sync for shop #{shop.id} due to job conflict: #{e.message}"
            # Don't fail the job, just skip this shop and continue
          rescue => e
            Rails.logger.error "Failed to sync Shopify orders for shop #{shop.id}: #{e.message}"
            Rails.logger.error e.backtrace.join("\n")
          end
        end
      end
    end

    private

    def sync_shop_with_coordination(shop)
      JobCoordinationService.with_job_coordination(shop.id, "order_sync", job_id) do
        sync_shop(shop)
      end
    end

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
      return if orders.empty?

      # Sort orders by creation date to ensure chronological processing (#6)
      sorted_orders = orders.sort_by { |order| order["createdAt"] }

      active_order_ids = []

      sorted_orders.each do |order_data|
        begin
          # Use the new enhanced order processing service with idempotency
          result = OrderProcessingService.process_order_with_idempotency(
            order_data,
            "shopify",
            @shop
          )

          # Use the helper method for consistent logging
          OrderProcessingService.log_processing_result(result, extract_id_from_gid(order_data["id"]), "Shopify")

          # Only add to active_order_ids if this was actually processed (not cached)
          if result[:success] && !OrderProcessingService.cached_result?(result)
            active_order_ids << result[:order].id
          end

        rescue OrderProcessingService::OrderProcessingError => e
          Rails.logger.error "Failed to process Shopify order #{extract_id_from_gid(order_data['id'])}: #{e.message}"
        rescue => e
          Rails.logger.error "Unexpected error processing Shopify order #{extract_id_from_gid(order_data['id'])}: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
        end
      end
    end

    # Legacy methods - now handled by OrderProcessingService
    # Keeping these as private methods for potential single order updates

    private

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
                      product {
                        id
                      }
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

        # Use the enhanced order processing service
        OrderProcessingService.process_order_with_idempotency(
          order_data,
          "shopify",
          @shop
        )
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
