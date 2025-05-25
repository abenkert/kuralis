# ========================================
# CACHE TESTING SCRIPT
# ========================================
# Run in rails console: load 'cache_test.rb'

puts "🗄️ CACHE TESTING & VERIFICATION"
puts "=" * 50

# Test cache connectivity
puts "\n1. 🔌 CACHE CONNECTIVITY TEST"
puts "-" * 30
begin
  test_key = "cache_test:#{Time.current.to_i}"
  test_value = "Hello Cache!"

  Rails.cache.write(test_key, test_value, expires_in: 1.minute)
  retrieved = Rails.cache.read(test_key)

  if retrieved == test_value
    puts "✅ Cache is working properly"
    Rails.cache.delete(test_key) # cleanup
  else
    puts "❌ Cache issue: wrote '#{test_value}' but got '#{retrieved}'"
  end
rescue => e
  puts "❌ Cache error: #{e.message}"
end

# Test order processing cache key creation
puts "\n2. 📦 ORDER PROCESSING CACHE TEST"
puts "-" * 30

# Create a test order data structure
test_order_data = {
  "orderId" => "TEST-ORDER-#{Time.current.to_i}",
  "orderFulfillmentStatus" => "NOT_STARTED",
  "lineItems" => [
    {
      "legacyItemId" => "123456789",
      "title" => "Test Product",
      "quantity" => 1
    }
  ]
}

# Test idempotency key generation
shop = Shop.find(2)
service = OrderProcessingService.new(test_order_data, "ebay", shop)
idempotency_key = service.send(:generate_order_idempotency_key)

puts "Generated idempotency key: #{idempotency_key}"

# Test cache key creation manually
order_processed_key = "order_processed:#{idempotency_key}"
order_result_key = "order_result:#{idempotency_key}"

# Write test cache entries
Rails.cache.write(order_processed_key, true, expires_in: 1.minute)
Rails.cache.write(order_result_key, { test: "result" }, expires_in: 1.minute)

# Verify they exist
if Rails.cache.exist?(order_processed_key)
  puts "✅ Order processed cache key exists"
else
  puts "❌ Order processed cache key missing"
end

if Rails.cache.exist?(order_result_key)
  puts "✅ Order result cache key exists"
  result = Rails.cache.read(order_result_key)
  puts "   Result data: #{result}"
else
  puts "❌ Order result cache key missing"
end

# Test status change creates different key
test_order_data_shipped = test_order_data.dup
test_order_data_shipped["orderFulfillmentStatus"] = "IN_TRANSIT"

service_shipped = OrderProcessingService.new(test_order_data_shipped, "ebay", shop)
idempotency_key_shipped = service_shipped.send(:generate_order_idempotency_key)

if idempotency_key != idempotency_key_shipped
  puts "✅ Status change creates different cache key"
  puts "   Original: #{idempotency_key}"
  puts "   Shipped:  #{idempotency_key_shipped}"
else
  puts "❌ Status change did NOT create different key"
end

# Clean up test keys
Rails.cache.delete(order_processed_key)
Rails.cache.delete(order_result_key)

# Test inventory sync job cache
puts "\n3. 🔄 INVENTORY SYNC JOB CACHE TEST"
puts "-" * 30

# Find a test product
test_product = shop.kuralis_products.first

if test_product
  # Test job deduplication cache key
  job_cache_key = "inventory_sync_job:#{test_product.id}:ebay"

  # Write test cache entry
  Rails.cache.write(job_cache_key, true, expires_in: 1.minute)

  if Rails.cache.exist?(job_cache_key)
    puts "✅ Inventory sync job cache key works"
    puts "   Key: #{job_cache_key}"
  else
    puts "❌ Inventory sync job cache key failed"
  end

  # Clean up
  Rails.cache.delete(job_cache_key)
else
  puts "❌ No test product found for inventory sync test"
end

# Test Redis lock cache
puts "\n4. 🔒 REDIS LOCK CACHE TEST"
puts "-" * 30

begin
  # Test Redis connection for locking
  redis_conn = Redis.new(url: ENV['REDIS_URL'] || 'redis://localhost:6379/0')

  # Test basic Redis operation
  test_lock_key = "test_lock:#{Time.current.to_i}"
  redis_conn.set(test_lock_key, "locked", ex: 10)

  if redis_conn.exists?(test_lock_key)
    puts "✅ Redis lock mechanism working"
    redis_conn.del(test_lock_key) # cleanup
  else
    puts "❌ Redis lock mechanism failed"
  end

  redis_conn.close
rescue => e
  puts "❌ Redis connection error: #{e.message}"
end

# Search for existing cache keys with our patterns
puts "\n5. 🔍 EXISTING CACHE KEYS SEARCH"
puts "-" * 30

# Note: This works with Redis, not memory store
begin
  redis_conn = Redis.new(url: ENV['REDIS_URL'] || 'redis://localhost:6379/0')

  # Search for our patterns
  order_keys = redis_conn.keys("order_processed:*")
  job_keys = redis_conn.keys("inventory_sync_job:*")
  lock_keys = redis_conn.keys("inventory_update:*")

  puts "Order processing keys found: #{order_keys.count}"
  order_keys.first(3).each { |key| puts "  #{key}" }
  puts "  ..." if order_keys.count > 3

  puts "Inventory job keys found: #{job_keys.count}"
  job_keys.first(3).each { |key| puts "  #{key}" }
  puts "  ..." if job_keys.count > 3

  puts "Lock keys found: #{lock_keys.count}"
  lock_keys.first(3).each { |key| puts "  #{key}" }
  puts "  ..." if lock_keys.count > 3

  redis_conn.close
rescue => e
  puts "Could not inspect Redis keys: #{e.message}"
  puts "(This is normal if using memory store instead of Redis)"
end

puts "\n✅ Cache testing complete!"
puts "=" * 50
