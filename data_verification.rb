# ========================================
# DATA VERIFICATION QUERIES
# ========================================
# Run these in rails console before/after sync
# Usage: rails console, then: load 'data_verification.rb'

puts "🏪 SHOP: #{Shop.find(2).shopify_domain}"
puts "=" * 50

# 1. CHECK FOR DUPLICATE ORDERS
puts "\n📋 1. CHECKING FOR DUPLICATE ORDERS"
puts "-" * 30
shop = Shop.find(2)

duplicate_orders = shop.orders
  .group(:platform, :platform_order_id)
  .having('COUNT(*) > 1')
  .count

if duplicate_orders.any?
  puts "❌ DUPLICATES FOUND:"
  duplicate_orders.each do |key, count|
    platform, order_id = key
    puts "  #{platform}: #{order_id} (#{count} copies)"
  end
else
  puts "✅ No duplicate orders found"
end

# 2. CHECK RECENT ORDERS SUMMARY
puts "\n📦 2. RECENT ORDERS SUMMARY"
puts "-" * 30
recent_orders = shop.orders.where('orders.created_at > ?', 24.hours.ago).order(:created_at)
puts "Recent orders (last 24h): #{recent_orders.count}"

recent_orders.each do |order|
  puts "  #{order.platform.upcase}: #{order.platform_order_id} - #{order.fulfillment_status} - Items: #{order.order_items.count}"
end

# 3. CHECK INVENTORY TRANSACTIONS
puts "\n💰 3. INVENTORY TRANSACTIONS STATUS"
puts "-" * 30
total_transactions = InventoryTransaction.joins(:kuralis_product)
  .where(kuralis_products: { shop_id: shop.id })

unprocessed = total_transactions.where(processed: false)
recent_transactions = total_transactions.where('inventory_transactions.created_at > ?', 24.hours.ago)

puts "Total inventory transactions: #{total_transactions.count}"
puts "Unprocessed transactions: #{unprocessed.count}"
puts "Recent transactions (24h): #{recent_transactions.count}"

if unprocessed.any?
  puts "\n⚠️  UNPROCESSED TRANSACTIONS:"
  unprocessed.limit(10).each do |t|
    puts "  #{t.kuralis_product.title}: #{t.transaction_type} #{t.quantity} (#{t.created_at.strftime('%m/%d %H:%M')})"
  end
end

# 4. CHECK PRODUCTS WITH INVENTORY DISCREPANCIES
puts "\n📊 4. INVENTORY CONSISTENCY CHECK"
puts "-" * 30

products_with_issues = []
shop.kuralis_products.includes(:shopify_product, :ebay_listing).each do |product|
  issues = []

  # Check Shopify sync
  if product.shopify_product.present?
    if product.shopify_product.quantity != product.base_quantity
      issues << "Shopify: #{product.shopify_product.quantity} vs Kuralis: #{product.base_quantity}"
    end
  end

  # Check eBay sync
  if product.ebay_listing.present?
    if product.ebay_listing.quantity != product.base_quantity
      issues << "eBay: #{product.ebay_listing.quantity} vs Kuralis: #{product.base_quantity}"
    end
  end

  if issues.any?
    products_with_issues << { product: product, issues: issues }
  end
end

if products_with_issues.any?
  puts "❌ INVENTORY DISCREPANCIES FOUND:"
  products_with_issues.first(5).each do |item|
    puts "  #{item[:product].title}:"
    item[:issues].each { |issue| puts "    - #{issue}" }
  end
  puts "  ... (showing first 5 of #{products_with_issues.count} products with issues)"
else
  puts "✅ All product inventories are in sync"
end

# 5. CHECK RECENT FAILED ALLOCATIONS
puts "\n⚠️  5. RECENT FAILED ALLOCATIONS"
puts "-" * 30
failed_allocations = InventoryTransaction
  .joins(:kuralis_product)
  .where(kuralis_products: { shop_id: shop.id })
  .where(transaction_type: 'allocation_failed')
  .where('inventory_transactions.created_at > ?', 24.hours.ago)
  .order('inventory_transactions.created_at')

if failed_allocations.any?
  puts "❌ RECENT ALLOCATION FAILURES:"
  failed_allocations.each do |t|
    puts "  #{t.kuralis_product.title}: Requested #{-t.quantity}, Available #{t.previous_quantity}"
    puts "    Order: #{t.order.platform_order_id} (#{t.created_at.strftime('%m/%d %H:%M')})"
  end
else
  puts "✅ No recent allocation failures"
end

# 6. CHECK PRODUCTS AT ZERO INVENTORY
puts "\n🚫 6. ZERO INVENTORY PRODUCTS"
puts "-" * 30
zero_inventory = shop.kuralis_products.where(base_quantity: 0)
puts "Products with zero inventory: #{zero_inventory.count}"

zero_inventory.limit(5).each do |product|
  status_info = []
  status_info << "Status: #{product.status}"
  status_info << "Shopify: #{product.shopify_product&.status}" if product.shopify_product
  status_info << "eBay: #{product.ebay_listing&.ebay_status}" if product.ebay_listing

  puts "  #{product.title} (#{status_info.join(', ')})"
end

# 7. CACHE STATUS CHECK
puts "\n🗄️  7. CACHE STATUS"
puts "-" * 30
begin
  # Try to connect to Redis and check for our cache patterns
  redis_conn = Redis.new(url: ENV['REDIS_URL'] || 'redis://localhost:6379/0')

  # Search for our specific cache patterns
  order_processed_keys = redis_conn.keys("order_processed:*")
  order_result_keys = redis_conn.keys("order_result:*")
  inventory_job_keys = redis_conn.keys("inventory_sync_job:*")
  inventory_lock_keys = redis_conn.keys("inventory_update:*")

  total_keys = order_processed_keys.count + order_result_keys.count + inventory_job_keys.count + inventory_lock_keys.count

  puts "Total relevant cache keys: #{total_keys}"
  puts "Order processed keys: #{order_processed_keys.count}"
  puts "Order result keys: #{order_result_keys.count}"
  puts "Inventory job keys: #{inventory_job_keys.count}"
  puts "Inventory lock keys: #{inventory_lock_keys.count}"

  # Show some examples if they exist
  if order_processed_keys.any?
    puts "\nExample order processed keys:"
    order_processed_keys.first(3).each { |key| puts "  #{key}" }
  end

  if inventory_job_keys.any?
    puts "\nExample inventory job keys:"
    inventory_job_keys.first(3).each { |key| puts "  #{key}" }
  end

  redis_conn.close
rescue => e
  puts "Could not check Redis cache: #{e.message}"
  puts "(Checking Rails.cache instead...)"

  # Fallback to testing if Rails cache is working
  test_key = "verification_test:#{Time.current.to_i}"
  Rails.cache.write(test_key, "test", expires_in: 1.minute)

  if Rails.cache.exist?(test_key)
    puts "✅ Rails cache is working (but can't inspect keys)"
    Rails.cache.delete(test_key)
  else
    puts "❌ Rails cache may not be working"
  end
end

# 8. QUICK SPECIFIC PRODUCT CHECK (modify product ID as needed)
puts "\n🔍 8. SPECIFIC PRODUCT DETAIL CHECK"
puts "-" * 30
# Change this ID to check a specific product
test_product_id = shop.kuralis_products.joins(:ebay_listing).first&.id

if test_product_id
  product = KuralisProduct.find(test_product_id)
  puts "Product: #{product.title}"
  puts "  Kuralis Quantity: #{product.base_quantity}"
  puts "  Shopify Quantity: #{product.shopify_product&.quantity || 'N/A'}"

  if product.ebay_listing
    puts "  eBay Available: #{product.ebay_listing.quantity}"
    puts "  eBay Total: #{product.ebay_listing.total_quantity}"
    puts "  eBay Sold: #{product.ebay_listing.quantity_sold}"
    puts "  eBay Status: #{product.ebay_listing.quantity_status}"
    puts "  eBay Sold %: #{product.ebay_listing.sold_percentage}%" if product.ebay_listing.has_sales?
  else
    puts "  eBay Listing: N/A"
  end

  puts "  Status: #{product.status}"
  puts "  Last Update: #{product.last_inventory_update || 'Never'}"

  recent_transactions = product.inventory_transactions.where('inventory_transactions.created_at > ?', 24.hours.ago)
  puts "  Recent Transactions (24h): #{recent_transactions.count}"
  recent_transactions.each do |t|
    puts "    #{t.transaction_type}: #{t.quantity} (#{t.processed ? 'processed' : 'pending'})"
  end
end

puts "\n✅ Verification complete!"
puts "=" * 50
