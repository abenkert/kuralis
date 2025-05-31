class OrderProcessingService
  class OrderProcessingError < StandardError; end
  class DuplicateOrderError < StandardError; end

  # Cache TTL for processed orders
  IDEMPOTENCY_TTL = 7.days

  # Configuration: whether to cache failed processing results
  # Set to false to allow re-processing of failed orders (useful for debugging)
  CACHE_FAILED_RESULTS = ENV.fetch("CACHE_FAILED_ORDER_RESULTS", "false") == "true"

  def self.process_order_with_idempotency(order_data, platform, shop)
    new(order_data, platform, shop).process_with_idempotency
  end

  # Helper method to check if a result is from cache
  def self.cached_result?(result)
    result.is_a?(Hash) && result[:cached] == true
  end

  # Helper method to log processing results consistently
  def self.log_processing_result(result, order_id, platform)
    if cached_result?(result)
      if result[:success]
        Rails.logger.info "#{platform.capitalize} order #{order_id} already processed successfully (cached)"
      else
        Rails.logger.info "#{platform.capitalize} order #{order_id} already processed with errors (cached): #{result[:errors].join(', ')}"
      end
    elsif result[:success]
      Rails.logger.info "Successfully processed #{platform} order #{order_id}"
    else
      Rails.logger.warn "#{platform.capitalize} order #{order_id} processed with errors: #{result[:errors].join(', ')}"
    end
  end

  def initialize(order_data, platform, shop)
    @order_data = order_data
    @platform = platform.downcase
    @shop = shop
    @order = nil
    @processed_items = []
    @errors = []
  end

  def process_with_idempotency
    # Generate idempotency key from order data
    idempotency_key = generate_order_idempotency_key

    # Check if order was already processed
    if Rails.cache.exist?("order_processed:#{idempotency_key}")
      cached_result = Rails.cache.read("order_result:#{idempotency_key}")
      Rails.logger.info "Skipping duplicate order processing for key=#{idempotency_key} (returning cached result: success=#{cached_result[:success]})"

      # Add a flag to indicate this is a cached result
      cached_result[:cached] = true
      return cached_result
    end

    # Process the order within a transaction
    result = nil
    begin
      ActiveRecord::Base.transaction do
        result = process_order
      end

      # Cache successful result
      Rails.cache.write("order_processed:#{idempotency_key}", true, expires_in: IDEMPOTENCY_TTL)
      Rails.cache.write("order_result:#{idempotency_key}", result, expires_in: IDEMPOTENCY_TTL)

      Rails.logger.info "Successfully processed order: #{@order&.platform_order_id}"
      result

    rescue => e
      Rails.logger.error "Error processing order: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")

      # Don't cache failed processing attempts
      create_processing_error_notification(e)
      raise OrderProcessingError, "Failed to process order: #{e.message}"
    end
  end

  private

  def process_order
    # Step 1: Create or update the order record
    create_or_update_order

    # Step 2: Process order items and inventory
    process_order_items

    # Step 3: Handle order status changes
    handle_order_status_changes

    # Return processing summary
    {
      order: @order,
      processed_items: @processed_items,
      errors: @errors,
      success: @errors.empty?
    }
  end

  def create_or_update_order
    platform_order_id = extract_platform_order_id

    @order = @shop.orders.find_or_initialize_by(
      platform: @platform,
      platform_order_id: platform_order_id
    )

    # Update order attributes based on platform
    if @platform == "ebay"
      update_ebay_order_attributes
    elsif @platform == "shopify"
      update_shopify_order_attributes
    end

    @order.save!
  end

  def process_order_items
    line_items = extract_line_items

    line_items.each do |item_data|
      begin
        process_single_order_item(item_data)
      rescue => e
        @errors << "Failed to process item #{item_data}: #{e.message}"
        Rails.logger.error "Error processing order item: #{e.message}"
      end
    end
  end

  def process_single_order_item(item_data)
    # Extract item details based on platform
    if @platform == "ebay"
      process_ebay_order_item(item_data)
    elsif @platform == "shopify"
      process_shopify_order_item(item_data)
    end
  end

  def process_ebay_order_item(item_data)
    quantity = item_data["quantity"].to_i
    ebay_item_id = item_data["legacyItemId"]

    # Find the associated Kuralis product
    kuralis_product = EbayListing.find_by(ebay_item_id: ebay_item_id)&.kuralis_product

    # Create order item
    order_item = @order.order_items.find_or_initialize_by(
      platform: "ebay",
      platform_item_id: ebay_item_id
    )

    order_item.assign_attributes(
      title: item_data["title"],
      quantity: quantity,
      kuralis_product: kuralis_product
    )

    order_item.save!

    # Process inventory if we have a Kuralis product
    if kuralis_product && should_adjust_inventory?(kuralis_product)
      process_inventory_for_item(kuralis_product, quantity, order_item)
    end

    @processed_items << order_item
  end

  def process_shopify_order_item(item_data)
    quantity = item_data["quantity"].to_i
    product_id = extract_id_from_gid(item_data["product"]["id"]) if item_data["product"]

    return unless product_id # Skip if product was deleted

    # Find the associated Kuralis product
    kuralis_product = ShopifyProduct.find_by(shopify_product_id: product_id)&.kuralis_product

    # Create order item
    order_item = @order.order_items.find_or_initialize_by(
      platform: "shopify",
      platform_item_id: product_id
    )

    order_item.assign_attributes(
      title: item_data["title"],
      quantity: quantity,
      kuralis_product: kuralis_product
    )

    order_item.save!

    # Process inventory if we have a Kuralis product
    if kuralis_product && should_adjust_inventory?(kuralis_product)
      process_inventory_for_item(kuralis_product, quantity, order_item)
    end

    @processed_items << order_item
  end

  def process_inventory_for_item(kuralis_product, quantity, order_item)
    if order_cancelled?
      InventoryService.release_inventory(
        kuralis_product: kuralis_product,
        quantity: quantity,
        order: @order,
        order_item: order_item
      )
    else
      InventoryService.allocate_inventory(
        kuralis_product: kuralis_product,
        quantity: quantity,
        order: @order,
        order_item: order_item
      )
    end
  rescue InventoryService::InsufficientInventoryError => e
    @errors << "Insufficient inventory for #{kuralis_product.title}: #{e.message}"
    Rails.logger.warn "Insufficient inventory for order #{@order.platform_order_id}: #{e.message}"
  rescue => e
    @errors << "Inventory processing failed for #{kuralis_product.title}: #{e.message}"
    Rails.logger.error "Inventory processing error: #{e.message}"
  end

  def should_adjust_inventory?(kuralis_product)
    return false unless @shop.inventory_sync?
    return false unless @order.order_placed_at.present?

    # For products with platform associations, check when the platform listing was last synced
    # This prevents double-counting sales that occurred before we got the current inventory state
    case kuralis_product.source_platform
    when "ebay"
      # Use the eBay listing's last_sync_at timestamp (when we last got current inventory state)
      return false unless kuralis_product.ebay_listing.present?

      platform_sync_time = kuralis_product.ebay_listing.last_sync_at || kuralis_product.ebay_listing.created_at
      Rails.logger.debug "eBay order check: order_placed_at=#{@order.order_placed_at}, ebay_listing_last_sync_at=#{platform_sync_time}"

      # Enhanced logic for cancelled orders
      if @order.cancelled? && @order.cancelled_before?(platform_sync_time)
        # Order was cancelled before our last inventory sync, so the current inventory
        # already reflects the cancellation. Don't adjust.
        Rails.logger.debug "Cancelled order #{@order.platform_order_id} was cancelled before last sync (#{@order.cancelled_at} <= #{platform_sync_time}) - skipping inventory adjustment"
        return false
      end

      @order.order_placed_at > platform_sync_time

    when "shopify"
      # Use the Shopify product's last_synced_at timestamp (when we last got current inventory state)
      return false unless kuralis_product.shopify_product.present?

      platform_sync_time = kuralis_product.shopify_product.last_synced_at || kuralis_product.shopify_product.created_at
      Rails.logger.debug "Shopify order check: order_placed_at=#{@order.order_placed_at}, shopify_product_last_synced_at=#{platform_sync_time}"

      # Enhanced logic for cancelled orders
      if @order.cancelled? && @order.cancelled_before?(platform_sync_time)
        # Order was cancelled before our last inventory sync, so the current inventory
        # already reflects the cancellation. Don't adjust.
        Rails.logger.debug "Cancelled order #{@order.platform_order_id} was cancelled before last sync (#{@order.cancelled_at} <= #{platform_sync_time}) - skipping inventory adjustment"
        return false
      end

      @order.order_placed_at > platform_sync_time

    else
      # For products created directly in Kuralis (AI, manual), use the product's imported_at
      return false unless kuralis_product.imported_at.present?

      Rails.logger.debug "Direct product check: order_placed_at=#{@order.order_placed_at}, imported_at=#{kuralis_product.imported_at}"

      @order.order_placed_at > kuralis_product.imported_at
    end
  end

  def handle_order_status_changes
    # Handle any special order status logic here
    # This is where you could add logic for:
    # - Order fulfillment status changes
    # - Payment status updates
    # - Cancellation handling
    # - etc.
  end

  def order_cancelled?
    # Check if order is cancelled based on platform-specific logic
    case @platform
    when "ebay"
      @order_data.dig("orderFulfillmentStatus") == "CANCELLED" ||
        @order_data.dig("cancelStatus", "cancelState") == "CANCELED"
    when "shopify"
      @order_data["cancelled"] == true ||
        @order_data["displayFinancialStatus"]&.downcase == "cancelled"
    else
      false
    end
  end

  def extract_platform_order_id
    case @platform
    when "ebay"
      @order_data["orderId"]
    when "shopify"
      extract_id_from_gid(@order_data["id"])
    end
  end

  def extract_line_items
    case @platform
    when "ebay"
      @order_data["lineItems"] || []
    when "shopify"
      @order_data["lineItems"]["edges"]&.map { |edge| edge["node"] } || []
    end
  end

  def update_ebay_order_attributes
    order_status = determine_ebay_order_status
    shipping_cost = calculate_ebay_shipping_cost

    subtotal = BigDecimal(@order_data["pricingSummary"]["priceSubtotal"]["value"].to_s)
    total_price = BigDecimal(@order_data["pricingSummary"]["total"]["value"].to_s)

    # Extract cancellation information
    cancelled_at = nil
    cancellation_reason = nil
    if order_status == "cancelled"
      cancelled_at = extract_cancellation_date
      cancellation_reason = @order_data.dig("cancelStatus", "cancelReason") || "Order cancelled"
    end

    @order.assign_attributes(
      subtotal: subtotal,
      total_price: total_price,
      shipping_cost: shipping_cost,
      fulfillment_status: order_status,
      payment_status: @order_data["orderPaymentStatus"],
      paid_at: @order_data.dig("paymentSummary", "payments", 0, "paymentDate"),
      shipping_address: extract_ebay_shipping_address,
      customer_name: extract_ebay_buyer_name,
      order_placed_at: @order_data["creationDate"],
      cancelled_at: cancelled_at,
      cancellation_reason: cancellation_reason,
      last_synced_at: Time.current
    )
  end

  def update_shopify_order_attributes
    # Extract cancellation information
    cancelled_at = nil
    cancellation_reason = nil
    if @order_data["cancelled"] == true
      cancelled_at = @order_data["cancelledAt"]
      cancellation_reason = @order_data["cancelReason"] || "Order cancelled"
    end

    @order.assign_attributes(
      subtotal: @order_data["subtotalPriceSet"]["shopMoney"]["amount"].to_f,
      total_price: @order_data["totalPriceSet"]["shopMoney"]["amount"].to_f,
      shipping_cost: @order_data["totalShippingPriceSet"]["shopMoney"]["amount"].to_f,
      fulfillment_status: @order_data["displayFulfillmentStatus"]&.downcase,
      payment_status: @order_data["displayFinancialStatus"]&.downcase,
      paid_at: @order_data["processedAt"],
      shipping_address: nil, # Not available with current permissions
      customer_name: nil,    # Not available with current permissions
      order_placed_at: @order_data["createdAt"],
      cancelled_at: cancelled_at,
      cancellation_reason: cancellation_reason,
      last_synced_at: Time.current
    )
  end

  def determine_ebay_order_status
    order_status = @order_data["orderFulfillmentStatus"]
    if order_status == "NOT_STARTED" && @order_data.dig("cancelStatus", "cancelState") == "CANCELED"
      order_status = "cancelled"
    end
    order_status
  end

  def calculate_ebay_shipping_cost
    # Extract shipping cost from eBay order data
    @order_data["pricingSummary"]["deliveryCost"]["value"].to_f rescue 0.0
  end

  def extract_ebay_shipping_address
    address = @order_data.dig("fulfillmentStartInstructions", 0, "shippingStep", "shipTo")
    return {} unless address

    {
      name: address["fullName"],
      street1: address.dig("contactAddress", "addressLine1"),
      street2: address.dig("contactAddress", "addressLine2"),
      city: address.dig("contactAddress", "city"),
      state: address.dig("contactAddress", "stateOrProvince"),
      postal_code: address.dig("contactAddress", "postalCode"),
      country: address.dig("contactAddress", "countryCode")
    }
  end

  def extract_ebay_buyer_name
    @order_data.dig("buyer", "username") || "eBay Buyer"
  end

  def generate_order_idempotency_key
    # Create a unique key based on platform, order ID, and items
    platform_order_id = extract_platform_order_id
    line_items = extract_line_items

    # Include fulfillment status to allow status updates
    fulfillment_status = case @platform
    when "ebay"
      @order_data["orderFulfillmentStatus"]
    when "shopify"
      @order_data["displayFulfillmentStatus"]
    end

    # Include item count and total to detect order modifications
    items_hash = Digest::MD5.hexdigest(line_items.to_json)

    "order:#{@platform}:#{platform_order_id}:#{items_hash}:#{fulfillment_status}"
  end

  def extract_id_from_gid(gid)
    return nil if gid.blank?
    gid.split("/").last
  rescue
    Rails.logger.error "Failed to extract ID from GID: #{gid}"
    nil
  end

  def create_processing_error_notification(error)
    Notification.create!(
      shop_id: @shop.id,
      title: "Order Processing Error",
      message: "Failed to process #{@platform} order: #{error.message}",
      category: "order",
      status: "error",
      metadata: {
        platform: @platform,
        order_data: @order_data,
        error: error.message,
        error_class: error.class.name
      }
    )
  end

  def extract_cancellation_date
    # Extract cancellation date from platform-specific order data
    case @platform
    when "ebay"
      # eBay provides cancellation date in various places
      @order_data.dig("cancelStatus", "cancelRequestDate") ||
        @order_data.dig("cancelStatus", "cancelDate") ||
        @order_data.dig("modificationDate") # Fallback to modification date
    when "shopify"
      # Shopify provides cancelled_at timestamp
      @order_data["cancelledAt"]
    else
      nil
    end
  end
end
