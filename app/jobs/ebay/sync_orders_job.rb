module Ebay
  class SyncOrdersJob < ApplicationJob
    queue_as :default

    OLDER_ORDERS_CHECK_INTERVAL = 6.hours
    RECENT_WINDOW = 72.hours
    EXTENDED_WINDOW = 30.days
    FULFILLMENT_API_URL = "https://api.ebay.com/sell/fulfillment/v1/order"

    def perform(shop_id = nil)
      if shop_id
        sync_shop(Shop.find(shop_id))
      else
        Shop.find_each do |shop|
          next unless shop.shopify_ebay_account # Skip shops without eBay connection

          begin
            sync_shop(shop)
          rescue => e
            Rails.logger.error "Failed to sync eBay orders for shop #{shop.id}: #{e.message}"
            Rails.logger.error e.backtrace.join("\n")
          end
        end
      end
    end

    private

    def sync_shop(shop)
      @shop = shop
      @ebay_account = @shop.shopify_ebay_account
      @token = EbayTokenService.new(@shop).fetch_or_refresh_access_token

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

    def process_older_unfulfilled_orders
      # Find orders that aren't in a terminal state
      unfulfilled_orders = @shop.orders
                               .where(platform: "ebay")
                               .where.not(status: [ "completed", "cancelled" ])
                               .where("created_at > ?", EXTENDED_WINDOW.ago)

      unfulfilled_orders.find_each do |order|
        update_single_order(order)
      end

      # Set the last check timestamp
      Rails.cache.write(older_orders_cache_key, Time.current, expires_in: OLDER_ORDERS_CHECK_INTERVAL)
      Rails.logger.info "Processed older unfulfilled orders for shop #{@shop.id}"
    end

    def should_check_older_orders?
      last_check = Rails.cache.read(older_orders_cache_key)
      last_check.nil? || last_check < OLDER_ORDERS_CHECK_INTERVAL.ago
    end

    def older_orders_cache_key
      "ebay_older_orders_last_check:#{@shop.id}"
    end

    def fetch_orders(start_time)
      # TODO: Add pagination support if we ever have more than 100 orders.
      uri = URI(FULFILLMENT_API_URL)
      uri.query = URI.encode_www_form({
        filter: "creationdate:[#{start_time}]",
        limit: 100,
        offset: 0
      })

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@token}"
      request["Content-Type"] = "application/json"
      request["X-EBAY-C-MARKETPLACE-ID"] = "0"

      response = http.request(request)

      raise "eBay API Error: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    end

    def update_single_order(order)
      uri = URI("#{FULFILLMENT_API_URL}/#{order.platform_order_id}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@token}"
      request["Content-Type"] = "application/json"
      request["X-EBAY-C-MARKETPLACE-ID"] = "0"

      response = http.request(request)

      raise "eBay API Error: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

      order_details = JSON.parse(response.body)
      update_order_status(order, order_details)
    rescue => e
      Rails.logger.error "Failed to update order #{order.platform_order_id}: #{e.message}"
    end

    def process_orders(response)
      response["orders"].each do |ebay_order|
        begin
          order = @shop.orders.find_or_initialize_by(
            platform: "ebay",
            platform_order_id: ebay_order["orderId"]
          )

          update_order_status(order, ebay_order)
        rescue => e
          Rails.logger.error "Failed to process order #{ebay_order['orderId']}: #{e.message}"
        end
      end
    end

    def update_order_status(order, ebay_order)
      order_status = determine_order_status(ebay_order)
      shipping_cost = calc_shipping_cost(ebay_order)

      # Convert string values to BigDecimal for proper decimal arithmetic
      subtotal = BigDecimal(ebay_order["pricingSummary"]["priceSubtotal"]["value"].to_s)
      total_price = BigDecimal(ebay_order["pricingSummary"]["total"]["value"].to_s)

      order.assign_attributes(
        subtotal: subtotal,
        total_price: total_price,
        shipping_cost: shipping_cost,
        fulfillment_status: order_status,
        payment_status: ebay_order["orderPaymentStatus"],
        paid_at: ebay_order["paymentSummary"]["payments"]&.first&.dig("paymentDate"),
        shipping_address: extract_shipping_address(ebay_order),
        customer_name: extract_buyer_name(ebay_order),
        order_placed_at: ebay_order["creationDate"]
      )

      # I DONT THINK WE NEED THIS STATUS FIELD SINCE WE HAVE PAYMENT AND FULFILLMENT STATUS
      # status: map_fulfillment_status(ebay_order['fulfillmentStatus']),

      order.save!
      process_order_items(order, ebay_order)
    end

    def determine_order_status(ebay_order)
      order_status = ebay_order["orderFulfillmentStatus"]
      order_status = "cancelled" if order_status == "NOT_STARTED" && ebay_order["cancelStatus"]["cancelState"] == "CANCELED"

      order_status
    end

    def calc_shipping_cost(ebay_order)
      # Convert string values to BigDecimal for proper decimal arithmetic
      shipping_cost = BigDecimal(ebay_order["pricingSummary"]["deliveryCost"]["value"].to_s)

      # Safely handle shipping discount which might not exist
      shipping_discount = if ebay_order.dig("pricingSummary", "deliveryDiscount", "value")
                           BigDecimal(ebay_order.dig("pricingSummary", "deliveryDiscount", "value").to_s)
      else
                           BigDecimal("0")
      end

      # Shipping discount is a negative value, so we add it to the shipping cost
      shipping_cost = shipping_cost + shipping_discount

      # Return as BigDecimal
      shipping_cost
    end

    def map_fulfillment_status(status)
      case status
      when "NOT_STARTED" then "pending"
      when "IN_PROGRESS" then "processing"
      when "FULFILLED" then "completed"
      when "FAILED" then "failed"
      else "pending"
      end
    end

    def extract_shipping_address(ebay_order)
      address = ebay_order["fulfillmentStartInstructions"]&.first&.dig("shippingStep", "shipTo")
      return {} unless address

      {
        name: address["fullName"],
        street1: address["contactAddress"]["addressLine1"],
        street2: address["contactAddress"]["addressLine2"],
        city: address["contactAddress"]["city"],
        state: address["contactAddress"]["stateOrProvince"],
        postal_code: address["contactAddress"]["postalCode"],
        country: address["contactAddress"]["countryCode"],
        phone: address.dig("primaryPhone", "phoneNumber")
      }
    end

    def extract_buyer_name(ebay_order)
      ebay_order["buyer"]["username"]
    end

    def process_order_items(order, ebay_order)
      ebay_order["lineItems"].each do |line_item|
        # Ensure quantity is an integer
        quantity = line_item["quantity"].to_i

        # Find the associated Kuralis product
        kuralis_product = EbayListing.find_by(ebay_item_id: line_item["legacyItemId"])&.kuralis_product

        # Find or initialize the order item with all attributes
        order_item = order.order_items.find_or_initialize_by(
          platform: "ebay",
          platform_item_id: line_item["legacyItemId"]
        )

        # Set all attributes
        order_item.assign_attributes(
          title: line_item["title"],
          quantity: quantity,
          kuralis_product: kuralis_product
        )

        # Save the order item to get an id
        order_item.save!

        # Process inventory if we have a Kuralis product
        if kuralis_product
          # Only adjust inventory if inventory sync is enabled and this is a new order
          # or an order that happened AFTER the product was imported
          should_adjust_inventory = @shop.inventory_sync? &&
                                      (
                                        kuralis_product.imported_at.present? &&
                                        order.order_placed_at.present? &&
                                        order.order_placed_at > kuralis_product.imported_at
                                      )


          if should_adjust_inventory
            if order.cancelled?
              ::InventoryService.release_inventory(
                kuralis_product: kuralis_product,
                quantity: quantity,
                order: order,
                order_item: order_item
              )
            else
              ::InventoryService.allocate_inventory(
                kuralis_product: kuralis_product,
                quantity: quantity,
                order: order,
                order_item: order_item
              )
            end
          else
            Rails.logger.info "Skipping inventory adjustment for historical order: #{order.platform_order_id}. Order date: #{order.order_placed_at}, Product import date: #{kuralis_product.imported_at}"
          end
        end
      end
    end
  end
end
