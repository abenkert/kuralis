class PlatformSyncRetryJob < ApplicationJob
  queue_as :inventory

  # Don't retry this job automatically - we handle retries manually
  discard_on StandardError

  def perform(shop_id = nil, failure_record_id, retry_count)
    failure_record = PlatformSyncFailure.find_by(id: failure_record_id)
    return unless failure_record

    Rails.logger.info "Retrying platform sync for failure_record_id=#{failure_record_id}, attempt #{retry_count}"

    # Update retry count
    failure_record.increment_retry_count!

    kuralis_product = failure_record.kuralis_product
    failed_platforms = failure_record.failed_platforms

    # Attempt to sync only the failed platforms
    sync_results = {}
    errors = []

    failed_platforms.each do |platform|
      begin
        result = sync_platform(kuralis_product, platform)
        sync_results[platform] = result

        if result[:success]
          Rails.logger.info "Successfully synced #{platform} for product_id=#{kuralis_product.id} on retry"
        else
          errors << result[:error]
          Rails.logger.error "Failed to sync #{platform} for product_id=#{kuralis_product.id} on retry: #{result[:error]}"
        end
      rescue => e
        error_msg = "Exception syncing #{platform}: #{e.message}"
        errors << error_msg
        sync_results[platform] = { success: false, error: error_msg }
        Rails.logger.error error_msg
      end
    end

    # Update failure record based on results
    update_failure_record(failure_record, sync_results, errors)

    # Schedule next retry if needed
    schedule_next_retry_if_needed(failure_record)
  end

  private

  def sync_platform(kuralis_product, platform)
    case platform.to_s
    when "shopify"
      sync_shopify(kuralis_product)
    when "ebay"
      sync_ebay(kuralis_product)
    else
      { success: false, error: "Unknown platform: #{platform}" }
    end
  end

  def sync_shopify(kuralis_product)
    return { success: false, error: "No Shopify product associated" } unless kuralis_product.shopify_product

    service = Shopify::InventoryService.new(
      kuralis_product.shopify_product,
      kuralis_product
    )

    success = service.update_inventory

    if success
      { success: true, platform: "shopify" }
    else
      { success: false, platform: "shopify", error: "Shopify inventory update failed" }
    end
  rescue => e
    { success: false, platform: "shopify", error: "Shopify sync exception: #{e.message}" }
  end

  def sync_ebay(kuralis_product)
    return { success: false, error: "No eBay listing associated" } unless kuralis_product.ebay_listing

    service = Ebay::InventoryService.new(
      kuralis_product.ebay_listing,
      kuralis_product
    )

    success = service.update_inventory

    if success
      { success: true, platform: "ebay" }
    else
      { success: false, platform: "ebay", error: "eBay inventory update failed" }
    end
  rescue => e
    { success: false, platform: "ebay", error: "eBay sync exception: #{e.message}" }
  end

  def update_failure_record(failure_record, sync_results, errors)
    successful_platforms = sync_results.select { |_, result| result[:success] }.keys
    still_failed_platforms = sync_results.select { |_, result| !result[:success] }.keys

    if still_failed_platforms.empty?
      # All platforms succeeded - mark as resolved
      failure_record.mark_resolved!
      Rails.logger.info "Platform sync failure #{failure_record.id} resolved - all platforms now synced"

      # Mark inventory transactions as processed
      mark_transactions_processed(failure_record.kuralis_product)

    elsif successful_platforms.any?
      # Partial success - update the failed platforms list
      failure_record.update!(
        failed_platforms: still_failed_platforms,
        successful_platforms: failure_record.successful_platforms + successful_platforms,
        error_details: errors,
        status: "retrying"
      )
      Rails.logger.info "Partial success for failure #{failure_record.id}: #{successful_platforms.join(', ')} now synced"

    else
      # Still failing - keep current state but update error details
      failure_record.update!(
        error_details: errors,
        status: "retrying"
      )
      Rails.logger.warn "No progress on failure #{failure_record.id} - all platforms still failing"
    end
  end

  def schedule_next_retry_if_needed(failure_record)
    failure_record.reload

    return unless failure_record.can_retry?
    return if failure_record.resolved?

    if failure_record.retry_count >= PlatformSyncRecoveryService::MAX_RETRIES
      failure_record.mark_abandoned!
      Rails.logger.error "Abandoning sync failure #{failure_record.id} after #{failure_record.retry_count} retries"

      # Create final notification
      create_abandonment_notification(failure_record)
      return
    end

    # Schedule next retry
    wait_time = PlatformSyncRecoveryService::RETRY_INTERVALS[failure_record.retry_count] || PlatformSyncRecoveryService::RETRY_INTERVALS.last

    PlatformSyncRetryJob.set(wait: wait_time).perform_later(
      failure_record.id,
      failure_record.retry_count + 1
    )

    Rails.logger.info "Scheduled next retry for failure #{failure_record.id} in #{wait_time}"
  end

  def mark_transactions_processed(kuralis_product)
    unprocessed_count = kuralis_product.inventory_transactions
                                      .where(processed: false)
                                      .update_all(processed: true)

    Rails.logger.info "Marked #{unprocessed_count} transactions as processed for product_id=#{kuralis_product.id}"
  end

  def create_abandonment_notification(failure_record)
    Notification.create!(
      shop: failure_record.shop,
      title: "Platform Sync Abandoned",
      message: "Unable to sync inventory for '#{failure_record.kuralis_product.title}' after multiple retries. Manual intervention required.",
      category: "platform_sync",
      status: "error",
      metadata: {
        kuralis_product_id: failure_record.kuralis_product_id,
        sync_failure_id: failure_record.id,
        failed_platforms: failure_record.failed_platforms,
        retry_count: failure_record.retry_count
      }
    )
  end
end
