module Ebay
  class SyncOrdersJob < ApplicationJob
    queue_as :default

    OLDER_ORDERS_CHECK_INTERVAL = 6.hours
    RECENT_WINDOW = 72.hours
    EXTENDED_WINDOW = 30.days
    FULFILLMENT_API_URL = "https://api.ebay.com/sell/fulfillment/v1/order"

    def perform(shop_id = nil)
      if shop_id
        sync_shop_with_coordination(Shop.find(shop_id))
      else
        Shop.find_each do |shop|
          next unless shop.shopify_ebay_account # Skip shops without eBay connection

          # TODO: We definitely need to look into not just looping through the shops. This makes it delayed for certain shops.
          begin
            sync_shop_with_coordination(shop)
          rescue JobCoordinationService::JobConflictError => e
            Rails.logger.warn "Skipping eBay order sync for shop #{shop.id} due to job conflict: #{e.message}"
            # Don't fail the job, just skip this shop and continue
          rescue => e
            Rails.logger.error "Failed to sync eBay orders for shop #{shop.id}: #{e.message}"
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

      # Use the enhanced order processing service
      OrderProcessingService.process_order_with_idempotency(
        order_details,
        "ebay",
        @shop
      )
    rescue => e
      Rails.logger.error "Failed to update order #{order.platform_order_id}: #{e.message}"
    end

    def process_orders(response)
      return unless response["orders"]

      # Sort orders by creation date to ensure chronological processing (#6)
      sorted_orders = response["orders"].sort_by { |order| order["creationDate"] }

      sorted_orders.each do |ebay_order|
        begin
          # Use the new enhanced order processing service with idempotency
          result = OrderProcessingService.process_order_with_idempotency(
            ebay_order,
            "ebay",
            @shop
          )

          # Use the helper method for consistent logging
          OrderProcessingService.log_processing_result(result, ebay_order["orderId"], "eBay")

        rescue OrderProcessingService::OrderProcessingError => e
          Rails.logger.error "Failed to process eBay order #{ebay_order['orderId']}: #{e.message}"
        rescue => e
          Rails.logger.error "Unexpected error processing eBay order #{ebay_order['orderId']}: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
        end
      end
    end

    # Legacy methods - now handled by OrderProcessingService
    # Keeping these as private methods for potential single order updates

    private

    def update_single_order_legacy(order, ebay_order)
      # Use the new service for single order updates too
      OrderProcessingService.process_order_with_idempotency(
        ebay_order,
        "ebay",
        @shop
      )
    end
  end
end
