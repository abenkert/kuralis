namespace :cleanup do
  desc "Clean up expired job locks and sync failures"
  task job_coordination: :environment do
    puts "🧹 Starting job coordination cleanup..."

    # Clean up expired job locks
    cleaned_locks = JobCoordinationService.cleanup_expired_locks
    puts "✅ Cleaned #{cleaned_locks} expired job locks"

    # Clean up old sync failures
    PlatformSyncRecoveryService.cleanup_old_failures
    puts "✅ Cleaned up old platform sync failures"

    # Clean up orphaned cache keys (orders and inventory)
    puts "🗑️ Clearing orphaned cache keys..."
    total_cache_cleared = 0

    if Rails.cache.respond_to?(:redis)
      Rails.cache.redis.with do |conn|
        # Get valid shop IDs
        valid_shop_ids = Shop.pluck(:id).to_set

        # Patterns that might contain shop references
        cache_patterns = [
          "order_processed:*",
          "order_result:*",
          "inventory_processed:*",
          "inventory_result:*",
          "*_older_orders_last_check:*"
        ]

        cache_patterns.each do |pattern|
          keys = conn.keys(pattern)
          orphaned_keys = []

          keys.each do |key|
            # Check if key references a non-existent shop
            # This is a simplified check - could be enhanced
            if key.match(/shop[_:](\d+)/) || key.match(/:(\d+):/)
              shop_id = $1.to_i
              unless valid_shop_ids.include?(shop_id)
                orphaned_keys << key
              end
            end
          end

          if orphaned_keys.any?
            conn.del(*orphaned_keys)
            total_cache_cleared += orphaned_keys.size
            puts "   Removed #{orphaned_keys.size} orphaned '#{pattern}' keys"
          end
        end
      end
    end

    puts "✅ Cleared #{total_cache_cleared} orphaned cache entries"

    # Retry any pending sync failures
    retry_count = 0
    PlatformSyncFailure.needs_retry.find_each do |failure|
      PlatformSyncRetryJob.perform_later(failure.id, failure.retry_count + 1)
      retry_count += 1
    end
    puts "🔄 Scheduled #{retry_count} sync failure retries"

    puts "✨ Job coordination cleanup completed!"
  end

  desc "Show job coordination statistics"
  task job_stats: :environment do
    puts "📊 Job Coordination Statistics"
    puts "=" * 50

    # Active job locks
    Shop.find_each do |shop|
      active_jobs = JobCoordinationService.active_jobs(shop.id)
      if active_jobs.any?
        puts "Shop #{shop.shopify_domain} (ID: #{shop.id}):"
        active_jobs.each do |job|
          puts "  - #{job[:job_type]} (started: #{job[:started_at]})"
        end
        puts
      end
    end

    # Sync failure stats
    failure_stats = PlatformSyncRecoveryService.get_failure_stats
    puts "Platform Sync Failures:"
    failure_stats.each do |stat, count|
      puts "  - #{stat.to_s.humanize}: #{count}"
    end

    puts "\n📈 Recent Activity (last 24h): #{failure_stats[:last_24h]} failures"
  end

  desc "Inspect all active job locks in Redis"
  task inspect_job_locks: :environment do
    puts "🔍 ACTIVE JOB LOCKS INSPECTION"
    puts "=" * 50

    if JobCoordinationService.redis_connection
      redis = JobCoordinationService.redis_connection
      pattern = "job_lock:*"
      keys = redis.keys(pattern)

      if keys.empty?
        puts "✅ No active job locks found"
        next
      end

      puts "Found #{keys.length} active job locks:"
      puts

      keys.each do |key|
        begin
          lock_info = redis.get(key)
          ttl = redis.ttl(key)

          # Parse lock info
          if lock_info
            info = JSON.parse(lock_info)
            started_at = Time.parse(info["started_at"]) rescue "Invalid"
            age = started_at.is_a?(Time) ? Time.current - started_at : "Unknown"

            puts "🔒 #{key}"
            puts "   Started: #{started_at}"
            puts "   Age: #{age.is_a?(Numeric) ? "#{(age / 60).round(1)} minutes" : age}"
            puts "   TTL: #{ttl == -1 ? 'No expiration' : "#{ttl} seconds"}"
            puts "   Job ID: #{info['job_id']}"
            puts "   PID: #{info['pid']}"
            puts "   Host: #{info['hostname']}"

            # Check if lock is expired
            if started_at.is_a?(Time) && started_at < JobCoordinationService::MAX_LOCK_TIME.ago
              puts "   ⚠️  EXPIRED (older than #{JobCoordinationService::MAX_LOCK_TIME / 1.minute} minutes)"
            end
          else
            puts "🔒 #{key}"
            puts "   ❌ CORRUPTED (no data)"
          end
          puts
        rescue => e
          puts "🔒 #{key}"
          puts "   ❌ ERROR: #{e.message}"
          puts
        end
      end

      # Check for expired locks
      expired_count = 0
      keys.each do |key|
        begin
          lock_info = redis.get(key)
          if lock_info
            info = JSON.parse(lock_info)
            started_at = Time.parse(info["started_at"])
            if started_at < JobCoordinationService::MAX_LOCK_TIME.ago
              expired_count += 1
            end
          else
            expired_count += 1 # Corrupted locks are considered expired
          end
        rescue
          expired_count += 1
        end
      end

      if expired_count > 0
        puts "⚠️  Found #{expired_count} expired/corrupted locks"
        puts "💡 Run 'rails cleanup:force_clear_job_locks' to clean them up"
      end
    else
      puts "❌ Redis not available"
    end
  end

  desc "Force clear all job locks (USE WITH CAUTION)"
  task force_clear_job_locks: :environment do
    puts "⚠️  FORCE CLEARING ALL JOB LOCKS"
    puts "=" * 50
    puts "This will clear ALL active job locks, including legitimate ones!"
    puts "Only use this if you're sure no critical jobs are running."
    puts

    if JobCoordinationService.redis_connection
      redis = JobCoordinationService.redis_connection
      pattern = "job_lock:*"
      keys = redis.keys(pattern)

      if keys.empty?
        puts "✅ No job locks to clear"
      else
        puts "Found #{keys.length} job locks to clear:"
        keys.each { |key| puts "  - #{key}" }
        puts

        # Clear all locks
        cleared = redis.del(*keys)
        puts "✅ Cleared #{cleared} job locks"
      end
    else
      puts "❌ Redis not available"
    end
  end

  desc "Clear expired job locks only"
  task clear_expired_job_locks: :environment do
    puts "🧹 Clearing expired job locks..."

    cleaned = JobCoordinationService.cleanup_expired_locks
    puts "✅ Cleaned #{cleaned} expired job locks"

    if cleaned == 0
      puts "💡 If you're still seeing conflicts, check with 'rails cleanup:inspect_job_locks'"
    end
  end

  desc "Clear job lock for specific shop (USE WITH CAUTION)"
  task :clear_shop_job_locks, [ :shop_id ] => :environment do |t, args|
    if args[:shop_id].blank?
      puts "Please specify a shop ID:"
      puts "  rails cleanup:clear_shop_job_locks[1]"
      exit 1
    end

    shop_id = args[:shop_id].to_i
    shop = Shop.find_by(id: shop_id)

    unless shop
      puts "❌ Shop not found: #{shop_id}"
      exit 1
    end

    puts "🧹 Clearing job locks for shop #{shop_id} (#{shop.shopify_domain})..."

    if JobCoordinationService.redis_connection
      redis = JobCoordinationService.redis_connection
      pattern = "job_lock:#{shop_id}:*"
      keys = redis.keys(pattern)

      if keys.empty?
        puts "✅ No job locks found for this shop"
      else
        puts "Found #{keys.length} job locks:"
        keys.each { |key| puts "  - #{key}" }
        puts

        cleared = redis.del(*keys)
        puts "✅ Cleared #{cleared} job locks for shop #{shop_id}"
      end
    else
      puts "❌ Redis not available"
    end
  end
end
