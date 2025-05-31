class JobCoordinationService
  class JobConflictError < StandardError; end

  # Job types that can conflict with each other
  JOB_CONFLICTS = {
    "order_sync" => [ "inventory_import", "inventory_sync" ],
    "inventory_import" => [ "order_sync", "inventory_sync" ],
    "inventory_sync" => [ "order_sync", "inventory_import" ]
  }.freeze

  # Maximum time a job lock should be held (prevents stuck locks)
  MAX_LOCK_TIME = 30.minutes

  def self.redis_connection
    @redis_connection ||= Redis.new(
      url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0")
    )
  end

  # Acquire a job lock for a specific shop and job type
  def self.acquire_job_lock(shop_id, job_type, job_id = nil)
    redis = redis_connection
    lock_key = "job_lock:#{shop_id}:#{job_type}"

    # Check for conflicting jobs
    conflicting_jobs = JOB_CONFLICTS[job_type] || []
    conflicting_jobs.each do |conflict_type|
      conflict_key = "job_lock:#{shop_id}:#{conflict_type}"
      if redis.exists?(conflict_key)
        conflict_info = redis.get(conflict_key)
        Rails.logger.warn "Job conflict detected: #{job_type} blocked by #{conflict_type} (#{conflict_info})"
        raise JobConflictError, "Cannot start #{job_type} while #{conflict_type} is running for shop #{shop_id}"
      end
    end

    # Try to acquire the lock
    lock_info = {
      job_id: job_id,
      started_at: Time.current.iso8601,
      pid: Process.pid,
      hostname: Socket.gethostname
    }.to_json

    success = redis.set(lock_key, lock_info, nx: true, ex: MAX_LOCK_TIME.to_i)

    if success
      Rails.logger.info "Acquired job lock: #{lock_key} (#{job_id})"
      lock_key
    else
      existing_info = redis.get(lock_key)
      Rails.logger.warn "Failed to acquire job lock: #{lock_key} (existing: #{existing_info})"
      raise JobConflictError, "Job #{job_type} already running for shop #{shop_id}"
    end
  end

  # Release a job lock
  def self.release_job_lock(shop_id, job_type, job_id = nil)
    redis = redis_connection
    lock_key = "job_lock:#{shop_id}:#{job_type}"

    # Only release if it's our lock
    current_lock = redis.get(lock_key)
    if current_lock
      lock_info = JSON.parse(current_lock)
      if job_id.nil? || lock_info["job_id"] == job_id
        redis.del(lock_key)
        Rails.logger.info "Released job lock: #{lock_key}"
        return true
      end
    end

    false
  rescue => e
    Rails.logger.error "Failed to release job lock #{lock_key}: #{e.message}"
    false
  end

  # Execute a job with coordination (with retry logic)
  def self.with_job_coordination(shop_id, job_type, job_id = nil, max_wait_attempts: 3, wait_interval: 10.seconds)
    lock_key = nil
    attempts = 0

    # Try to acquire lock with retries
    while attempts < max_wait_attempts
      begin
        lock_key = acquire_job_lock(shop_id, job_type, job_id)
        break # Successfully acquired lock
      rescue JobConflictError => e
        attempts += 1
        if attempts >= max_wait_attempts
          Rails.logger.warn "Failed to acquire #{job_type} lock for shop #{shop_id} after #{max_wait_attempts} attempts, failing job"
          raise e
        else
          Rails.logger.info "#{job_type} lock busy for shop #{shop_id}, waiting #{wait_interval} seconds (attempt #{attempts}/#{max_wait_attempts})"
          sleep(wait_interval)
        end
      end
    end

    # Execute the job
    yield
  ensure
    release_job_lock(shop_id, job_type, job_id) if lock_key
  end

  # Check if a job can run (without acquiring lock)
  def self.can_run_job?(shop_id, job_type)
    redis = redis_connection

    # Check for direct conflict
    lock_key = "job_lock:#{shop_id}:#{job_type}"
    return false if redis.exists?(lock_key)

    # Check for conflicting job types
    conflicting_jobs = JOB_CONFLICTS[job_type] || []
    conflicting_jobs.each do |conflict_type|
      conflict_key = "job_lock:#{shop_id}:#{conflict_type}"
      return false if redis.exists?(conflict_key)
    end

    true
  end

  # Get current job locks for a shop
  def self.active_jobs(shop_id)
    redis = redis_connection
    pattern = "job_lock:#{shop_id}:*"
    keys = redis.keys(pattern)
    active_jobs = []

    keys.each do |key|
      begin
        lock_info = redis.get(key)
        next unless lock_info

        info = JSON.parse(lock_info)
        job_type = key.split(":").last

        active_jobs << {
          job_type: job_type,
          started_at: Time.parse(info["started_at"]),
          job_id: info["job_id"],
          hostname: info["hostname"],
          pid: info["pid"]
        }
      rescue => e
        Rails.logger.warn "Error parsing job lock #{key}: #{e.message}"
      end
    end

    active_jobs.sort_by { |job| job[:started_at] }
  rescue => e
    Rails.logger.error "Failed to get active jobs for shop #{shop_id}: #{e.message}"
    []
  end

  # Clean up expired job locks
  def self.cleanup_expired_locks
    redis = redis_connection
    pattern = "job_lock:*"
    keys = redis.keys(pattern)
    cleaned_count = 0

    keys.each do |key|
      begin
        lock_info = redis.get(key)
        next unless lock_info

        info = JSON.parse(lock_info)
        started_at = Time.parse(info["started_at"])

        # Remove locks older than MAX_LOCK_TIME
        if started_at < MAX_LOCK_TIME.ago
          redis.del(key)
          cleaned_count += 1
          Rails.logger.info "Cleaned expired job lock: #{key}"
        end
      rescue => e
        # Remove corrupted locks
        redis.del(key)
        cleaned_count += 1
        Rails.logger.warn "Cleaned corrupted job lock #{key}: #{e.message}"
      end
    end

    cleaned_count
  rescue => e
    Rails.logger.error "Failed to cleanup expired locks: #{e.message}"
    0
  end

  # Check if a specific job type is locked for a shop
  def self.job_locked?(shop_id, job_type)
    redis = redis_connection
    lock_key = "job_lock:#{shop_id}:#{job_type}"
    redis.exists?(lock_key)
  rescue => e
    Rails.logger.error "Failed to check job lock #{lock_key}: #{e.message}"
    false
  end
end
