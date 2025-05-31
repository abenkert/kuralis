namespace :orders do
  desc "Clean up orders and their cache entries for testing"

  desc "Destroy all orders and clear cache"
  task :destroy_all, [ :shop_domain ] => :environment do |t, args|
    if args[:shop_domain].blank?
      puts "Please specify a shop domain:"
      puts "  rails orders:destroy_all[shop-name.myshopify.com]"
      exit 1
    end

    shop = Shop.find_by(shopify_domain: args[:shop_domain])
    unless shop
      puts "Shop not found: #{args[:shop_domain]}"
      exit 1
    end

    orders = shop.orders
    count = orders.count

    if count == 0
      puts "No orders found for shop: #{shop.shopify_domain}"
      exit 0
    end

    puts "Found #{count} orders for shop: #{shop.shopify_domain}"
    puts "🗑️  Clearing cache and destroying orders..."

    cache_cleared = clear_orders_cache(orders)
    destroyed_count = destroy_orders_with_cleanup(orders)

    puts "✅ Successfully destroyed #{destroyed_count} orders and cleared #{cache_cleared} cache entries"
  end

  desc "Destroy orders by platform and clear cache"
  task :destroy_by_platform, [ :shop_domain, :platform ] => :environment do |t, args|
    if args[:shop_domain].blank? || args[:platform].blank?
      puts "Please specify shop domain and platform:"
      puts "  rails orders:destroy_by_platform[shop-name.myshopify.com,ebay]"
      puts "  rails orders:destroy_by_platform[shop-name.myshopify.com,shopify]"
      exit 1
    end

    shop = Shop.find_by(shopify_domain: args[:shop_domain])
    unless shop
      puts "Shop not found: #{args[:shop_domain]}"
      exit 1
    end

    platform = args[:platform].downcase
    unless %w[ebay shopify].include?(platform)
      puts "Invalid platform. Use 'ebay' or 'shopify'"
      exit 1
    end

    orders = shop.orders.where(platform: platform)
    count = orders.count

    if count == 0
      puts "No #{platform} orders found for shop: #{shop.shopify_domain}"
      exit 0
    end

    puts "Found #{count} #{platform} orders for shop: #{shop.shopify_domain}"
    puts "🗑️  Clearing cache and destroying orders..."

    cache_cleared = clear_orders_cache(orders)
    destroyed_count = destroy_orders_with_cleanup(orders)

    puts "✅ Successfully destroyed #{destroyed_count} #{platform} orders and cleared #{cache_cleared} cache entries"
  end

  desc "Destroy recent orders (last N days) and clear cache"
  task :destroy_recent, [ :shop_domain, :days ] => :environment do |t, args|
    if args[:shop_domain].blank?
      puts "Please specify shop domain and optional days:"
      puts "  rails orders:destroy_recent[shop-name.myshopify.com]  # Last 7 days"
      puts "  rails orders:destroy_recent[shop-name.myshopify.com,3]  # Last 3 days"
      exit 1
    end

    shop = Shop.find_by(shopify_domain: args[:shop_domain])
    unless shop
      puts "Shop not found: #{args[:shop_domain]}"
      exit 1
    end

    days = (args[:days] || "7").to_i
    cutoff_date = days.days.ago

    orders = shop.orders.where("created_at > ?", cutoff_date)
    count = orders.count

    if count == 0
      puts "No orders found in the last #{days} days for shop: #{shop.shopify_domain}"
      exit 0
    end

    puts "Found #{count} orders from the last #{days} days for shop: #{shop.shopify_domain}"
    puts "🗑️  Clearing cache and destroying orders..."

    cache_cleared = clear_orders_cache(orders)
    destroyed_count = destroy_orders_with_cleanup(orders)

    puts "✅ Successfully destroyed #{destroyed_count} recent orders and cleared #{cache_cleared} cache entries"
  end

  desc "Clear cache for specific order IDs"
  task :clear_cache, [ :shop_domain, :order_ids ] => :environment do |t, args|
    if args[:shop_domain].blank? || args[:order_ids].blank?
      puts "Please specify shop domain and comma-separated order IDs:"
      puts "  rails orders:clear_cache[shop-name.myshopify.com,'123,456,789']"
      exit 1
    end

    shop = Shop.find_by(shopify_domain: args[:shop_domain])
    unless shop
      puts "Shop not found: #{args[:shop_domain]}"
      exit 1
    end

    order_ids = args[:order_ids].split(",").map(&:strip).map(&:to_i)
    orders = shop.orders.where(id: order_ids)

    if orders.empty?
      puts "No orders found with IDs: #{order_ids.join(', ')}"
      exit 0
    end

    puts "Found #{orders.count} orders to clear cache for"
    puts "🧹 Clearing cache entries..."

    cache_keys_cleared = clear_orders_cache(orders)

    puts "✅ Successfully cleared #{cache_keys_cleared} cache entries"
  end

  desc "Clear ALL cache (orders, inventory, locks, jobs)"
  task clear_complete_cache: :environment do
    puts "🧹 Clearing ALL system cache (orders, inventory, locks, job coordination)..."

    total_cleared = 0

    # Clear all cache using Redis pattern matching
    if Rails.cache.respond_to?(:redis)
      Rails.cache.redis.with do |conn|
        # Order processing cache
        order_processed_keys = conn.keys("order_processed:*")
        if order_processed_keys.any?
          conn.del(*order_processed_keys)
          total_cleared += order_processed_keys.size
          puts "   Cleared #{order_processed_keys.size} 'order_processed' cache entries"
        end

        order_result_keys = conn.keys("order_result:*")
        if order_result_keys.any?
          conn.del(*order_result_keys)
          total_cleared += order_result_keys.size
          puts "   Cleared #{order_result_keys.size} 'order_result' cache entries"
        end

        # Inventory processing cache
        inventory_processed_keys = conn.keys("inventory_processed:*")
        if inventory_processed_keys.any?
          conn.del(*inventory_processed_keys)
          total_cleared += inventory_processed_keys.size
          puts "   Cleared #{inventory_processed_keys.size} 'inventory_processed' cache entries"
        end

        inventory_result_keys = conn.keys("inventory_result:*")
        if inventory_result_keys.any?
          conn.del(*inventory_result_keys)
          total_cleared += inventory_result_keys.size
          puts "   Cleared #{inventory_result_keys.size} 'inventory_result' cache entries"
        end

        # Inventory locks
        inventory_lock_keys = conn.keys("inventory_lock:*")
        if inventory_lock_keys.any?
          conn.del(*inventory_lock_keys)
          total_cleared += inventory_lock_keys.size
          puts "   Cleared #{inventory_lock_keys.size} 'inventory_lock' entries"
        end

        # Job coordination locks
        job_lock_keys = conn.keys("job_lock:*")
        if job_lock_keys.any?
          conn.del(*job_lock_keys)
          total_cleared += job_lock_keys.size
          puts "   Cleared #{job_lock_keys.size} 'job_lock' entries"
        end

        # Shopify bulk import cache
        shopify_bulk_keys = conn.keys("shopify_bulk_import:*")
        if shopify_bulk_keys.any?
          conn.del(*shopify_bulk_keys)
          total_cleared += shopify_bulk_keys.size
          puts "   Cleared #{shopify_bulk_keys.size} 'shopify_bulk_import' cache entries"
        end

        # Order sync cache (older orders check)
        order_sync_keys = conn.keys("*_older_orders_last_check:*")
        if order_sync_keys.any?
          conn.del(*order_sync_keys)
          total_cleared += order_sync_keys.size
          puts "   Cleared #{order_sync_keys.size} 'order_sync' cache entries"
        end
      end
    else
      # Fallback for non-Redis cache stores
      Rails.cache.clear
      total_cleared = "ALL"
      puts "   Cleared ALL cache (non-Redis cache store)"
    end

    puts "✅ Successfully cleared #{total_cleared} total cache entries"
  end

  # Alias for backward compatibility
  desc "Clear ALL order cache (pattern-based) - DEPRECATED: use clear_complete_cache"
  task :clear_all_cache, [ :shop_domain ] => :environment do |t, args|
    puts "⚠️  Note: clear_all_cache is deprecated. Use 'clear_complete_cache' for full cleanup."
    puts "🔄 Redirecting to complete cache clear..."
    Rake::Task["orders:clear_complete_cache"].invoke
  end

  desc "Clear inventory-specific cache"
  task clear_inventory_cache: :environment do
    puts "🧹 Clearing inventory-specific cache..."

    total_cleared = 0

    if Rails.cache.respond_to?(:redis)
      Rails.cache.redis.with do |conn|
        # Inventory processing cache
        inventory_processed_keys = conn.keys("inventory_processed:*")
        if inventory_processed_keys.any?
          conn.del(*inventory_processed_keys)
          total_cleared += inventory_processed_keys.size
          puts "   Cleared #{inventory_processed_keys.size} 'inventory_processed' cache entries"
        end

        inventory_result_keys = conn.keys("inventory_result:*")
        if inventory_result_keys.any?
          conn.del(*inventory_result_keys)
          total_cleared += inventory_result_keys.size
          puts "   Cleared #{inventory_result_keys.size} 'inventory_result' cache entries"
        end

        # Inventory locks
        inventory_lock_keys = conn.keys("inventory_lock:*")
        if inventory_lock_keys.any?
          conn.del(*inventory_lock_keys)
          total_cleared += inventory_lock_keys.size
          puts "   Cleared #{inventory_lock_keys.size} 'inventory_lock' entries"
        end
      end
    else
      puts "   Non-Redis cache store - use orders:clear_complete_cache instead"
    end

    puts "✅ Successfully cleared #{total_cleared} inventory cache entries"
  end

  desc "Show order cache status"
  task :cache_status, [ :shop_domain ] => :environment do |t, args|
    if args[:shop_domain].blank?
      puts "Please specify a shop domain:"
      puts "  rails orders:cache_status[shop-name.myshopify.com]"
      exit 1
    end

    shop = Shop.find_by(shopify_domain: args[:shop_domain])
    unless shop
      puts "Shop not found: #{args[:shop_domain]}"
      exit 1
    end

    orders = shop.orders.includes(:order_items).limit(20)

    puts "📊 CACHE STATUS FOR #{shop.shopify_domain}"
    puts "=" * 50
    puts "Checking cache for #{orders.count} most recent orders..."
    puts

    cached_count = 0
    total_cache_keys = 0

    # Check Redis-wide cache status if available
    if Rails.cache.respond_to?(:redis)
      Rails.cache.redis.with do |conn|
        processed_keys = conn.keys("order_processed:*")
        result_keys = conn.keys("order_result:*")
        total_cache_keys = processed_keys.size + result_keys.size
        puts "🗂️  Total cache entries in Redis: #{total_cache_keys} order-related keys"
        puts
      end
    end

    orders.each do |order|
      cache_keys = generate_cache_keys_for_order(order)

      processed_cached = Rails.cache.exist?(cache_keys[:processed])
      result_cached = Rails.cache.exist?(cache_keys[:result])

      if processed_cached || result_cached
        cached_count += 1
        puts "📦 Order #{order.platform_order_id} (#{order.platform.upcase})"
        puts "   Processed Cache: #{processed_cached ? '✅ EXISTS' : '❌ MISSING'}"
        puts "   Result Cache: #{result_cached ? '✅ EXISTS' : '❌ MISSING'}"

        # Show cache keys for debugging
        puts "   Keys:"
        puts "     #{cache_keys[:processed]}"
        puts "     #{cache_keys[:result]}"
        puts
      end
    end

    puts "📈 Summary: #{cached_count}/#{orders.count} recent orders have cache entries"
    puts "📈 Total Redis cache keys: #{total_cache_keys}" if total_cache_keys > 0
  end

  desc "Show all cache key patterns and counts"
  task inspect_cache: :environment do
    puts "🔍 REDIS CACHE INSPECTION"
    puts "=" * 50

    if Rails.cache.respond_to?(:redis)
      Rails.cache.redis.with do |conn|
        patterns = [
          "order_processed:*",
          "order_result:*",
          "inventory_processed:*",
          "inventory_result:*",
          "inventory_lock:*",
          "job_lock:*",
          "shopify_bulk_import:*",
          "*_older_orders_last_check:*"
        ]

        total_keys = 0

        patterns.each do |pattern|
          keys = conn.keys(pattern)
          count = keys.size
          total_keys += count

          puts "#{pattern.ljust(30)} #{count.to_s.rjust(8)} keys"

          # Show a few examples if they exist
          if count > 0 && count <= 5
            keys.each { |key| puts "  └─ #{key}" }
          elsif count > 5
            keys.first(3).each { |key| puts "  ├─ #{key}" }
            puts "  ├─ ... (#{count - 5} more)"
            keys.last(2).each { |key| puts "  └─ #{key}" }
          end
          puts
        end

        puts "📊 SUMMARY: #{total_keys} total cache keys found"

        # Check for any orphaned keys with non-existent shop IDs
        puts "\n🔍 Checking for orphaned keys..."
        valid_shop_ids = Shop.pluck(:id).to_set
        orphaned_count = 0

        patterns.each do |pattern|
          keys = conn.keys(pattern)
          keys.each do |key|
            # Try to extract shop_id from key structure if possible
            if key.match(/shop[_:](\d+)/) || key.match(/:(\d+):/)
              shop_id = $1.to_i
              unless valid_shop_ids.include?(shop_id)
                orphaned_count += 1
                puts "  ⚠️ Orphaned: #{key} (shop_id: #{shop_id})"
              end
            end
          end
        end

        if orphaned_count > 0
          puts "\n❌ Found #{orphaned_count} potentially orphaned keys"
          puts "💡 Run 'rails orders:clear_complete_cache' to clean up"
        else
          puts "\n✅ No obviously orphaned keys found"
        end
      end
    else
      puts "❌ Redis not available or using different cache store"
      puts "💡 Current cache store: #{Rails.cache.class}"
    end
  end

  private

  def clear_orders_cache(orders)
    total_cleared = 0
    cache_keys_to_delete = []

    # Collect all cache keys first
    orders.find_each do |order|
      cache_keys = generate_cache_keys_for_order(order)
      cache_keys_to_delete << cache_keys[:processed]
      cache_keys_to_delete << cache_keys[:result]
    end

    # Bulk delete cache keys
    if cache_keys_to_delete.any?
      if Rails.cache.respond_to?(:redis)
        # Use Redis connection pool correctly
        Rails.cache.redis.with do |conn|
          # Filter keys that actually exist (handle both boolean and integer returns)
          existing_keys = cache_keys_to_delete.select { |key| conn.exists?(key) }
          if existing_keys.any?
            conn.del(*existing_keys)
            total_cleared = existing_keys.size
          end
        end
      else
        # Fallback for other cache stores
        cache_keys_to_delete.each do |key|
          total_cleared += 1 if Rails.cache.delete(key)
        end
      end
    end

    total_cleared
  end

  def destroy_orders_with_cleanup(orders)
    destroyed_count = 0

    orders.find_each do |order|
      begin
        # Also destroy related inventory transactions
        order.inventory_transactions.destroy_all
        order.destroy!
        destroyed_count += 1
      rescue => e
        puts "❌ Failed to destroy order #{order.id}: #{e.message}"
      end
    end

    destroyed_count
  end

  def generate_cache_keys_for_order(order)
    # Recreate the cache keys using the same logic as OrderProcessingService
    line_items = order.order_items.map do |item|
      {
        "title" => item.title,
        "quantity" => item.quantity,
        "platform_item_id" => item.platform_item_id
      }
    end

    items_hash = Digest::MD5.hexdigest(line_items.to_json)
    fulfillment_status = order.fulfillment_status || "unknown"

    idempotency_key = "order:#{order.platform}:#{order.platform_order_id}:#{items_hash}:#{fulfillment_status}"

    {
      processed: "order_processed:#{idempotency_key}",
      result: "order_result:#{idempotency_key}"
    }
  end
end
