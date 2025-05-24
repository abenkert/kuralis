class OrderProcessingService
  class OrderProcessingError < StandardError; end
  class DuplicateOrderError < StandardError; end

  # Cache TTL for processed orders
  IDEMPOTENCY_TTL = 7.days

  def self.process_order_with_idempotency(order_data, platform, shop)
    new(order_data, platform, shop).process_with_idempotency
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
      Rails.logger.info "Skipping duplicate order processing for key=#{idempotency_key}"
      return Rails.cache.read("order_result:#{idempotency_key}")
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
    @shop.inventory_sync? &&
      kuralis_product.imported_at.present? &&
      @order.order_placed_at.present? &&
      @order.order_placed_at > kuralis_product.imported_at
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

    @order.assign_attributes(
      subtotal: subtotal,
      total_price: total_price,
      shipping_cost: shipping_cost,
      fulfillment_status: order_status,
      payment_status: @order_data["orderPaymentStatus"],
      paid_at: @order_data["paymentSummary"]["payments"]&.first&.dig("paymentDate"),
      shipping_address: extract_ebay_shipping_address,
      customer_name: extract_ebay_buyer_name,
      order_placed_at: @order_data["creationDate"],
      last_synced_at: Time.current
    )
  end

  def update_shopify_order_attributes
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
      last_synced_at: Time.current
    )
  end

  def determine_ebay_order_status
    order_status = @order_data["orderFulfillmentStatus"]
    if order_status == "NOT_STARTED" && @order_data["cancelStatus"]["cancelState"] == "CANCELED"
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
      street1: address["contactAddress"]["addressLine1"],
      street2: address["contactAddress"]["addressLine2"],
      city: address["contactAddress"]["city"],
      state: address["contactAddress"]["stateOrProvince"],
      postal_code: address["contactAddress"]["postalCode"],
      country: address["contactAddress"]["countryCode"]
    }
  end

  def extract_ebay_buyer_name
    @order_data.dig("buyer", "username") || "eBay Buyer"
  end

  def generate_order_idempotency_key
    # Create a unique key based on platform, order ID, and items
    platform_order_id = extract_platform_order_id
    line_items = extract_line_items

    # Include item count and total to detect order modifications
    items_hash = Digest::MD5.hexdigest(line_items.to_json)

    "order:#{@platform}:#{platform_order_id}:#{items_hash}"
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
end
