namespace :test do
  desc "Test eBay order flow with a single order"
  task ebay_order_flow: :environment do
    puts "🚀 Starting eBay Single Order Flow Test"
    puts "=" * 50

    # Find a shop with eBay connection
    shop = Shop.joins(:shopify_ebay_account).first

    unless shop
      puts "❌ No shop found with eBay account connection"
      exit
    end

    puts "🏪 Testing with Shop: #{shop.shopify_domain} (ID: #{shop.id})"

    # Initialize the test service
    tester = EbayOrderFlowTester.new(shop)
    tester.test_single_order_flow
  end
end

class EbayOrderFlowTester
  FULFILLMENT_API_URL = "https://api.ebay.com/sell/fulfillment/v1/order"

  def initialize(shop)
    @shop = shop
    @ebay_account = @shop.shopify_ebay_account
    @token = EbayTokenService.new(@shop).fetch_or_refresh_access_token

    puts "🔑 eBay token obtained: #{@token[0..20]}..."
  end

  def test_single_order_flow
    puts "\n📡 Step 1: Fetching single order from eBay API"
    puts "-" * 30

    # Fetch just 1 recent order
    ebay_order = fetch_single_order

    unless ebay_order
      puts "❌ No orders found in eBay API"
      return
    end

    puts "✅ Order fetched: #{ebay_order['orderId']}"
    puts "📅 Order date: #{ebay_order['creationDate']}"
    puts "💰 Total: #{ebay_order['pricingSummary']['total']['value']} #{ebay_order['pricingSummary']['total']['currency']}"
    puts "📦 Items count: #{ebay_order['lineItems']&.count || 0}"

    # Show line items
    if ebay_order["lineItems"]
      puts "\n📋 Line Items:"
      ebay_order["lineItems"].each_with_index do |item, index|
        puts "  #{index + 1}. #{item['title']} (Qty: #{item['quantity']}, eBay ID: #{item['legacyItemId']})"

        # Check if we have this product in our system
        kuralis_product = EbayListing.find_by(ebay_item_id: item["legacyItemId"])&.kuralis_product
        if kuralis_product
          puts "     ✅ Found in Kuralis: #{kuralis_product.title} (Qty: #{kuralis_product.base_quantity})"
          puts "     📅 Imported at: #{kuralis_product.imported_at}"
        else
          puts "     ❌ Not found in Kuralis system"
        end
      end
    end

    puts "\n🔄 Step 2: Processing through enhanced OrderProcessingService"
    puts "-" * 50

    # Process through the enhanced service
    result = process_order_with_detailed_logging(ebay_order)

    puts "\n📊 Step 3: Final Results"
    puts "-" * 30
    puts "Success: #{result[:success]}"
    puts "Errors: #{result[:errors].join(', ')}" if result[:errors].any?
    puts "Order ID in DB: #{result[:order]&.id}"
    puts "Items processed: #{result[:processed_items]&.count || 0}"

    if result[:order]
      order = result[:order]
      puts "\n📋 Order Details in Database:"
      puts "  Platform Order ID: #{order.platform_order_id}"
      puts "  Subtotal: #{order.subtotal}"
      puts "  Total: #{order.total_price}"
      puts "  Fulfillment Status: #{order.fulfillment_status}"
      puts "  Payment Status: #{order.payment_status}"
      puts "  Order Items Count: #{order.order_items.count}"

      # Show inventory transactions created
      transactions = InventoryTransaction.joins(:order_item)
                                       .where(order_items: { order: order })

      puts "\n💰 Inventory Transactions Created: #{transactions.count}"
      transactions.each do |transaction|
        puts "  - Product: #{transaction.kuralis_product.title}"
        puts "    Type: #{transaction.transaction_type}"
        puts "    Quantity Change: #{transaction.quantity}"
        puts "    Previous: #{transaction.previous_quantity} → New: #{transaction.new_quantity}"
        puts "    Processed: #{transaction.processed}"
        puts ""
      end
    end

    puts "\n🎉 Test completed!"
  end

  private

  def fetch_single_order
    # Get orders from last 30 days but limit to 1
    start_time = 30.days.ago.iso8601

    uri = URI(FULFILLMENT_API_URL)
    uri.query = URI.encode_www_form({
      filter: "creationdate:[#{start_time}]",
      limit: 1,  # Just 1 order for testing
      offset: 0
    })

    puts "🌐 API URL: #{uri}"

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{@token}"
    request["Content-Type"] = "application/json"
    request["X-EBAY-C-MARKETPLACE-ID"] = "0"

    response = http.request(request)

    unless response.is_a?(Net::HTTPSuccess)
      puts "❌ eBay API Error: #{response.body}"
      return nil
    end

    data = JSON.parse(response.body)
    puts "📦 Total orders available: #{data['total']}"

    data["orders"]&.first
  end

  def process_order_with_detailed_logging(ebay_order)
    puts "🔄 Processing order through OrderProcessingService..."

    # Add some debug output to see the flow
    original_logger_level = Rails.logger.level
    Rails.logger.level = :debug if Rails.env.development?

    # Generate idempotency key to show
    order_id = ebay_order["orderId"]
    line_items = ebay_order["lineItems"] || []
    items_hash = Digest::MD5.hexdigest(line_items.to_json)
    idempotency_key = "order:ebay:#{order_id}:#{items_hash}"

    puts "🔑 Idempotency key: #{idempotency_key}"

    # Check if already processed
    if Rails.cache.exist?("order_processed:#{idempotency_key}")
      puts "⚠️  Order already processed (found in cache)"
      return Rails.cache.read("order_result:#{idempotency_key}")
    else
      puts "✅ Order not yet processed (cache miss)"
    end

    # Process the order
    begin
      result = OrderProcessingService.process_order_with_idempotency(
        ebay_order,
        "ebay",
        @shop
      )

      puts "✅ OrderProcessingService completed successfully"
      result

    rescue => e
      puts "❌ OrderProcessingService failed: #{e.message}"
      puts "Stack trace:"
      puts e.backtrace.first(5).join("\n")

      {
        success: false,
        errors: [ e.message ],
        order: nil,
        processed_items: []
      }
    ensure
      Rails.logger.level = original_logger_level
    end
  end
end
