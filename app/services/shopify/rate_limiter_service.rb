module Shopify
  class RateLimiterService
    # Shopify API limits (customize as needed)
    RATE_LIMIT_KEY = "shopify_api_rate_limit"
    RATE_LIMIT_MAX = 1000 # Shopify default bucket size
    RATE_LIMIT_RESTORE_RATE = 50 # Points restored per second (example)
    RATE_LIMIT_BUFFER = 100 # Minimum points to keep as buffer

    def initialize(shop_id)
      @shop_id = shop_id
      @redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"))
      @key = "#{RATE_LIMIT_KEY}:#{@shop_id}"
    end

    # Wait until enough points are available, then decrement the counter
    def wait_for_points!(points_needed)
      loop do
        current_points = current_points_available
        if current_points >= points_needed + RATE_LIMIT_BUFFER
          # Atomically decrement points
          @redis.decrby(@key, points_needed)
          break
        else
          sleep_time = 1
          sleep(sleep_time)
          restore_points(sleep_time)
        end
      end
    end

    # Update the counter based on Shopify's throttleStatus after each call
    def update_from_throttle_status(throttle_status)
      if throttle_status && throttle_status["currentlyAvailable"]
        @redis.set(@key, throttle_status["currentlyAvailable"])
      end
    end

    private

    def current_points_available
      points = @redis.get(@key)
      points ? points.to_i : RATE_LIMIT_MAX
    end

    def restore_points(seconds)
      # Simulate points restoration over time
      @redis.incrby(@key, RATE_LIMIT_RESTORE_RATE * seconds)
      # Cap at max
      if current_points_available > RATE_LIMIT_MAX
        @redis.set(@key, RATE_LIMIT_MAX)
      end
    end
  end
end
