class PlatformSyncRecoveryService
  class PlatformSyncRecoveryError < StandardError; end

  RETRY_INTERVALS = [ 5.minutes, 15.minutes, 1.hour, 4.hours ].freeze
  MAX_RETRIES = RETRY_INTERVALS.length

  def self.handle_sync_failure(kuralis_product, failed_platforms, successful_platforms, error_details)
    new(kuralis_product, failed_platforms, successful_platforms, error_details).handle_failure
  end

  def initialize(kuralis_product, failed_platforms, successful_platforms, error_details)
    @kuralis_product = kuralis_product
    @failed_platforms = Array(failed_platforms)
    @successful_platforms = Array(successful_platforms)
    @error_details = error_details
    @shop = kuralis_product.shop
  end

  def handle_failure
    Rails.logger.error "Platform sync failure for product_id=#{@kuralis_product.id}"
    Rails.logger.error "Failed platforms: #{@failed_platforms.join(', ')}"
    Rails.logger.error "Successful platforms: #{@successful_platforms.join(', ')}"

    # Create failure record for tracking
    failure_record = create_failure_record

    # Determine recovery strategy based on failure severity
    if critical_failure?
      handle_critical_failure(failure_record)
    else
      handle_recoverable_failure(failure_record)
    end

    # Send notification to user
    create_user_notification(failure_record)

    failure_record
  end

  private

  def create_failure_record
    PlatformSyncFailure.create!(
      kuralis_product: @kuralis_product,
      shop: @shop,
      failed_platforms: @failed_platforms,
      successful_platforms: @successful_platforms,
      error_details: @error_details,
      failure_type: determine_failure_type,
      retry_count: 0,
      status: "pending",
      created_at: Time.current
    )
  end

  def critical_failure?
    # Consider it critical if:
    # 1. All platforms failed
    # 2. More than half the platforms failed
    # 3. The failure affects inventory accuracy significantly
    total_platforms = (@failed_platforms + @successful_platforms).uniq.length
    return true if @successful_platforms.empty? && total_platforms > 0
    return true if @failed_platforms.length > total_platforms / 2.0
    false
  end

  def determine_failure_type
    if @failed_platforms.include?("shopify") && @failed_platforms.include?("ebay")
      "total_failure"
    elsif @failed_platforms.length == 1
      "partial_failure"
    else
      "multiple_failure"
    end
  end

  def handle_critical_failure(failure_record)
    Rails.logger.error "Critical platform sync failure detected for product_id=#{@kuralis_product.id}"

    # Mark inventory transactions as failed to prevent further processing
    @kuralis_product.inventory_transactions
                   .where(processed: false)
                   .update_all(
                     processed: true,
                     notes: "Marked as processed due to critical sync failure at #{Time.current}"
                   )

    # Schedule immediate retry with escalated priority
    schedule_recovery_retry(failure_record, immediate: true)

    # Create urgent notification
    failure_record.update!(
      status: "critical",
      escalated_at: Time.current
    )
  end

  def handle_recoverable_failure(failure_record)
    Rails.logger.warn "Recoverable platform sync failure for product_id=#{@kuralis_product.id}"

    # Schedule retry with backoff
    schedule_recovery_retry(failure_record)

    failure_record.update!(status: "retrying")
  end

  def schedule_recovery_retry(failure_record, immediate: false)
    retry_count = failure_record.retry_count

    if retry_count >= MAX_RETRIES
      Rails.logger.error "Max retries exceeded for sync failure record #{failure_record.id}"
      failure_record.update!(
        status: "failed",
        abandoned_at: Time.current
      )
      return
    end

    wait_time = immediate ? 30.seconds : RETRY_INTERVALS[retry_count]

    PlatformSyncRetryJob.set(wait: wait_time).perform_later(
      failure_record.id,
      retry_count + 1
    )

    Rails.logger.info "Scheduled retry #{retry_count + 1}/#{MAX_RETRIES} for sync failure #{failure_record.id} in #{wait_time}"
  end

  def create_user_notification(failure_record)
    severity = failure_record.status == "critical" ? "error" : "warning"

    Notification.create!(
      shop: @shop,
      title: "Platform Sync #{severity.titleize}",
      message: build_notification_message(failure_record),
      category: "platform_sync",
      status: severity,
      metadata: {
        kuralis_product_id: @kuralis_product.id,
        sync_failure_id: failure_record.id,
        failed_platforms: @failed_platforms,
        successful_platforms: @successful_platforms
      }
    )
  end

  def build_notification_message(failure_record)
    product_title = @kuralis_product.title.truncate(50)

    case failure_record.failure_type
    when "total_failure"
      "Failed to sync inventory for '#{product_title}' to all platforms. Manual intervention may be required."
    when "partial_failure"
      platform = @failed_platforms.first
      "Failed to sync inventory for '#{product_title}' to #{platform.titleize}. Retrying automatically."
    when "multiple_failure"
      platforms = @failed_platforms.join(" and ")
      "Failed to sync inventory for '#{product_title}' to #{platforms}. Retrying automatically."
    end
  end

  # Class methods for recovery operations

  def self.retry_failed_syncs
    # Find all pending and retrying failures that need attention
    PlatformSyncFailure.where(status: [ "pending", "retrying" ])
                      .where("created_at > ?", 24.hours.ago)
                      .where("retry_count < ?", MAX_RETRIES)
                      .find_each do |failure_record|
      PlatformSyncRetryJob.perform_later(
        failure_record.id,
        failure_record.retry_count + 1
      )
    end
  end

  def self.cleanup_old_failures
    cutoff_date = 7.days.ago

    # Remove old resolved failures
    resolved_count = PlatformSyncFailure.resolved
                      .where("resolved_at < ?", cutoff_date)
                      .delete_all

    # Remove old failed failures (after 30 days)
    failed_cutoff = 30.days.ago
    failed_count = PlatformSyncFailure.failed
                    .where("created_at < ?", failed_cutoff)
                    .delete_all

    total_cleaned = resolved_count + failed_count

    if total_cleaned > 0
      Rails.logger.info "Cleaned up #{total_cleaned} old platform sync failures (#{resolved_count} resolved, #{failed_count} failed)"
    end

    total_cleaned
  rescue => e
    Rails.logger.error "Failed to cleanup old platform sync failures: #{e.message}"
    0
  end

  def self.get_failure_stats
    stats = {}

    stats[:total] = PlatformSyncFailure.count
    stats[:pending] = PlatformSyncFailure.pending.count
    stats[:retrying] = PlatformSyncFailure.retrying.count
    stats[:critical] = PlatformSyncFailure.critical.count
    stats[:resolved] = PlatformSyncFailure.resolved.count
    stats[:failed] = PlatformSyncFailure.failed.count
    stats[:last_24h] = PlatformSyncFailure.where("created_at > ?", 24.hours.ago).count

    stats
  rescue => e
    Rails.logger.error "Failed to get platform sync failure stats: #{e.message}"
    {
      total: 0, pending: 0, retrying: 0, critical: 0,
      resolved: 0, failed: 0, last_24h: 0
    }
  end
end
