class ProductStatusService
  class StatusUpdateError < StandardError; end

  # Valid status transitions
  VALID_TRANSITIONS = {
    "active" => [ "inactive", "completed" ],
    "inactive" => [ "active", "completed" ],
    "completed" => [ "active", "inactive" ],
    "draft" => [ "active", "inactive" ]
  }.freeze

  # Redis connection for locking
  def redis_connection
    @redis_connection ||= Redis.new(
      url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0")
    )
  end

  def self.update_product_status(kuralis_product, new_status, reason: nil, user_id: nil)
    new(kuralis_product).update_status(new_status, reason: reason, user_id: user_id)
  end

  def initialize(kuralis_product)
    @kuralis_product = kuralis_product
    @shop = kuralis_product.shop
    @old_status = kuralis_product.status
    @errors = []
  end

  def update_status(new_status, reason: nil, user_id: nil)
    return false if new_status == @old_status

    # Validate status transition
    unless valid_transition?(new_status)
      @errors << "Invalid status transition from #{@old_status} to #{new_status}"
      return false
    end

    # Use distributed lock for status changes
    lock_key = "status_lock:#{@kuralis_product.id}"

    begin
      redis_connection.lock_for_update(lock_key) do
        update_status_atomic(new_status, reason, user_id)
      end
    rescue Timeout::Error
      @errors << "Could not acquire status lock within timeout"
      Rails.logger.error "Status lock timeout for product_id=#{@kuralis_product.id}"
      false
    rescue => e
      @errors << "Status update failed: #{e.message}"
      Rails.logger.error "Status update error for product_id=#{@kuralis_product.id}: #{e.message}"
      false
    end
  end

  def errors
    @errors
  end

  private

  def update_status_atomic(new_status, reason, user_id)
    ActiveRecord::Base.transaction do
      # Update the Kuralis product status
      @kuralis_product.update!(
        status: new_status,
        last_inventory_update: Time.current
      )

      # Log the status change
      log_status_change(new_status, reason, user_id)

      # Handle platform-specific status updates
      handle_platform_status_updates(new_status)

      # Create notification for significant status changes
      create_status_change_notification(new_status, reason)

      Rails.logger.info "Product #{@kuralis_product.id} status changed: #{@old_status} → #{new_status}"
      true
    end
  end

  def valid_transition?(new_status)
    return true unless VALID_TRANSITIONS.key?(@old_status)
    VALID_TRANSITIONS[@old_status].include?(new_status)
  end

  def handle_platform_status_updates(new_status)
    case new_status
    when "inactive", "completed"
      # End/disable listings on all platforms
      disable_all_platform_listings
    when "active"
      # Reactivate listings if inventory is available
      if @kuralis_product.base_quantity > 0
        reactivate_platform_listings
      else
        # If no inventory, keep as completed status
        @kuralis_product.update!(status: "completed")
      end
    end
  end

  def disable_all_platform_listings
    results = []

    # Disable Shopify product
    if @kuralis_product.shopify_product.present?
      result = disable_shopify_product
      results << { platform: "shopify", success: result }
    end

    # End eBay listing
    if @kuralis_product.ebay_listing.present?
      result = end_ebay_listing
      results << { platform: "ebay", success: result }
    end

    # Schedule async updates for better error handling
    if results.any? { |r| !r[:success] }
      schedule_platform_status_retry
    end

    results
  end

  def reactivate_platform_listings
    results = []

    # Reactivate Shopify product
    if @kuralis_product.shopify_product.present?
      result = reactivate_shopify_product
      results << { platform: "shopify", success: result }
    end

    # For eBay, we typically can't reactivate ended listings
    # Users would need to create new listings
    if @kuralis_product.ebay_listing.present?
      Rails.logger.info "eBay listing cannot be reactivated automatically - user must create new listing"
      results << { platform: "ebay", success: false, reason: "Manual reactivation required" }
    end

    results
  end

  def disable_shopify_product
    begin
      service = Shopify::EndProductService.new(@kuralis_product.shopify_product)
      service.end_product
    rescue => e
      Rails.logger.error "Failed to disable Shopify product: #{e.message}"
      false
    end
  end

  def reactivate_shopify_product
    begin
      service = Shopify::InventoryService.new(
        @kuralis_product.shopify_product,
        @kuralis_product
      )
      service.update_inventory
    rescue => e
      Rails.logger.error "Failed to reactivate Shopify product: #{e.message}"
      false
    end
  end

  def end_ebay_listing
    begin
      service = Ebay::EndListingService.new(@kuralis_product.ebay_listing)
      service.end_listing("NotAvailable")
    rescue => e
      Rails.logger.error "Failed to end eBay listing: #{e.message}"
      false
    end
  end

  def log_status_change(new_status, reason, user_id)
    # Create an inventory transaction to track status changes
    InventoryTransaction.create!(
      kuralis_product: @kuralis_product,
      quantity: 0, # No quantity change for status updates
      transaction_type: "status_change",
      previous_quantity: @kuralis_product.base_quantity,
      new_quantity: @kuralis_product.base_quantity,
      notes: "Status changed from #{@old_status} to #{new_status}. Reason: #{reason || 'Not specified'}",
      processed: true # Status changes are immediately processed
    )
  end

  def create_status_change_notification(new_status, reason)
    # Only notify for significant status changes
    return unless significant_status_change?(new_status)

    Notification.create!(
      shop_id: @shop.id,
      title: "Product Status Changed",
      message: "Product '#{@kuralis_product.title}' status changed from #{@old_status} to #{new_status}",
      category: "product",
      status: notification_status(new_status),
      metadata: {
        product_id: @kuralis_product.id,
        old_status: @old_status,
        new_status: new_status,
        reason: reason,
        timestamp: Time.current
      }
    )
  end

  def significant_status_change?(new_status)
    # Notify for changes to/from completed status or when going inactive
    (@old_status == "completed" || new_status == "completed") ||
    (@old_status == "active" && new_status == "inactive")
  end

  def notification_status(new_status)
    case new_status
    when "completed" then "warning"
    when "inactive" then "info"
    when "active" then "success"
    else "info"
    end
  end

  def schedule_platform_status_retry
    # Schedule a retry job for failed platform updates
    PlatformStatusRetryJob.set(wait: 1.minute).perform_later(@kuralis_product.id)
  end
end
