module Shopify
  class RateLimiterService
    class RateLimitError < StandardError; end

    # Shopify API limits
    RATE_LIMIT_KEY = "shopify_api_rate_limit"
    RATE_LIMIT_MAX = 1000 # Shopify default bucket size
    RATE_LIMIT_RESTORE_RATE = 100 # Points restored per second
    RATE_LIMIT_BUFFER = 50 # Safety buffer
    MAX_WAIT_TIME = 30 # Maximum seconds to wait for points
    MAX_RETRIES = 3 # Maximum number of Redis retries

    DECREMENT_SCRIPT = <<~LUA
      local key = KEYS[1]
      local points_needed = tonumber(ARGV[1])
      local current_points = tonumber(redis.call('get', key) or ARGV[2])

      if current_points >= points_needed then
        redis.call('decrby', key, points_needed)
        return 1
      else
        return 0
      end
    LUA

    RESTORE_SCRIPT = <<~LUA
      local key = KEYS[1]
      local points_to_add = tonumber(ARGV[1])
      local max_points = tonumber(ARGV[2])
      local current_points = tonumber(redis.call('get', key) or max_points)
      local new_points = math.min(current_points + points_to_add, max_points)

      redis.call('set', key, new_points)
      return new_points
    LUA

    def initialize(shop_id)
      @shop_id = shop_id
      @redis = Redis.new(
        url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0")
      )
      @key = "#{RATE_LIMIT_KEY}:#{@shop_id}"

      # Load scripts once during initialization
      load_lua_scripts
    end

    # Wait until enough points are available, then decrement the counter
    def wait_for_points!(points_needed)
      total_points_needed = points_needed + RATE_LIMIT_BUFFER
      start_time = Time.now

      loop do
        begin
          # Try to atomically decrement points
          success = execute_script(:decrement, total_points_needed)

          if success == 1
            break
          else
            # Check if we've waited too long
            raise RateLimitError, "Maximum wait time exceeded" if Time.now - start_time > MAX_WAIT_TIME

            # Calculate wait time based on current points and restoration rate
            current_points = current_points_available
            points_short = total_points_needed - current_points
            wait_time = [ (points_short.to_f / RATE_LIMIT_RESTORE_RATE).ceil, 1 ].max

            # Cap the wait time
            wait_time = [ wait_time, MAX_WAIT_TIME - (Time.now - start_time) ].min
            return false if wait_time <= 0

            sleep(wait_time)
            restore_points(wait_time)
          end
        rescue Redis::BaseError => e
          Rails.logger.error("Redis error in rate limiter: #{e.message}")
          raise RateLimitError, "Redis error: #{e.message}"
        end
      end

      true
    end

    # Update the counter based on Shopify's throttleStatus after each call
    def update_from_throttle_status(throttle_status)
      return unless throttle_status

      available = throttle_status["currentlyAvailable"].to_i
      maximum = throttle_status["maximumAvailable"].to_i

      if available > 0 && maximum > 0
        with_redis_retry do
          # Update both current and max if they've changed
          if maximum != RATE_LIMIT_MAX
            Rails.logger.warn("Shopify rate limit maximum has changed: #{maximum}")
          end

          @redis.set(@key, available)
        end
      end
    rescue Redis::BaseError => e
      Rails.logger.error("Failed to update throttle status: #{e.message}")
    end

    private

    def current_points_available
      with_redis_retry do
        points = @redis.get(@key)
        points ? points.to_i : RATE_LIMIT_MAX
      end
    end

    def restore_points(seconds)
      points_to_restore = RATE_LIMIT_RESTORE_RATE * seconds

      with_redis_retry do
        execute_script(:restore, points_to_restore)
      end
    end

    def load_lua_scripts
      @script_shas = {}

      with_redis_retry do
        @script_shas[:decrement] = @redis.script(:load, DECREMENT_SCRIPT)
        @script_shas[:restore] = @redis.script(:load, RESTORE_SCRIPT)
      end
    rescue Redis::BaseError => e
      Rails.logger.error("Failed to load Lua scripts: #{e.message}")
      raise RateLimitError, "Failed to initialize rate limiter"
    end

    def execute_script(script_name, *args)
      with_redis_retry do
        @redis.evalsha(@script_shas[script_name], keys: [ @key ], argv: args)
      end
    rescue Redis::CommandError => e
      if e.message.include?("NOSCRIPT")
        # Script was lost, reload and retry
        load_lua_scripts
        retry
      else
        raise
      end
    end

    def with_redis_retry
      retries = 0
      begin
        yield
      rescue Redis::BaseError => e
        retries += 1
        if retries <= MAX_RETRIES
          sleep(0.1 * retries) # Exponential backoff
          retry
        else
          raise
        end
      end
    end
  end
end
