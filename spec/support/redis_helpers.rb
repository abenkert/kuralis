# Redis testing helpers for inventory system
module RedisHelpers
  def with_redis_lock(key, &block)
    # Helper to test Redis locking functionality
    redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
    redis.set("lock:#{key}", "test", nx: true, ex: 60)
    yield
  ensure
    redis&.del("lock:#{key}")
  end

  def clear_redis_cache
    # Clear all cache and locks for clean test state
    if Rails.cache.respond_to?(:clear)
      Rails.cache.clear
    end

    if defined?(Redis) && Rails.env.test?
      begin
        redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
        redis.flushdb
      rescue Redis::CannotConnectError
        # Redis not available, skip
      end
    end
  end

  def expect_redis_key_exists(key)
    redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
    expect(redis.exists?(key)).to be_truthy
  end

  def expect_redis_key_not_exists(key)
    redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
    expect(redis.exists?(key)).to be_falsey
  end
end

RSpec.configure do |config|
  config.include RedisHelpers
end
