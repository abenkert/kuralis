require "redis-lock"

class InventoryService
  class InsufficientInventoryError < StandardError; end
  class InventoryLockError < StandardError; end
  class PlatformSyncError < StandardError; end

  # Maximum time to wait for a lock before giving up (in seconds)
  LOCK_TIMEOUT = 30
  REDIS_LOCK_TIMEOUT = 60

  # Redis connection for locking
  def self.redis_connection
    @redis_connection ||= Redis.new(
      url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0")
    )
  end

  # Enhanced allocation with distributed locking and atomic operations
  def self.allocate_inventory(kuralis_product:, quantity:, order:, order_item:)
    return unless kuralis_product && quantity && order && order_item

    # Generate idempotency key to prevent duplicate processing
    idempotency_key = generate_idempotency_key(order, order_item, "allocation")

    # Check if already processed
    if Rails.cache.exist?("inventory_processed:#{idempotency_key}")
      Rails.logger.info "Skipping duplicate allocation for idempotency_key=#{idempotency_key}"
      return Rails.cache.read("inventory_result:#{idempotency_key}")
    end

    Rails.logger.info "Allocating inventory for order_id=#{order.id}, product_id=#{kuralis_product.id}, quantity=#{quantity}"

    # Use distributed lock to prevent race conditions
    lock_key = "inventory_lock:#{kuralis_product.id}"

    begin
      redis_connection.lock_for_update(lock_key) do
        result = allocate_inventory_atomic(kuralis_product, quantity, order, order_item)

        # Cache the result with idempotency key
        Rails.cache.write("inventory_processed:#{idempotency_key}", true, expires_in: 7.days)
        Rails.cache.write("inventory_result:#{idempotency_key}", result, expires_in: 7.days)

        result
      end
    rescue Timeout::Error
      Rails.logger.error "LOCK TIMEOUT: Failed to acquire inventory lock for product_id=#{kuralis_product.id}"
      raise InventoryLockError, "Could not acquire inventory lock within #{LOCK_TIMEOUT} seconds"
    rescue => e
      Rails.logger.error "Error in inventory allocation: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      raise
    end
  end

  # Enhanced release with distributed locking
  def self.release_inventory(kuralis_product:, quantity:, order:, order_item:)
    return unless kuralis_product && quantity && order && order_item

    # Generate idempotency key
    idempotency_key = generate_idempotency_key(order, order_item, "release")

    # Check if already processed
    if Rails.cache.exist?("inventory_processed:#{idempotency_key}")
      Rails.logger.info "Skipping duplicate release for idempotency_key=#{idempotency_key}"
      return Rails.cache.read("inventory_result:#{idempotency_key}")
    end

    Rails.logger.info "Releasing inventory for order_id=#{order.id}, product_id=#{kuralis_product.id}, quantity=#{quantity}"

    lock_key = "inventory_lock:#{kuralis_product.id}"

    begin
      redis_connection.lock_for_update(lock_key) do
        result = release_inventory_atomic(kuralis_product, quantity, order, order_item)

        # Cache the result
        Rails.cache.write("inventory_processed:#{idempotency_key}", true, expires_in: 7.days)
        Rails.cache.write("inventory_result:#{idempotency_key}", result, expires_in: 7.days)

        result
      end
    rescue Timeout::Error
      Rails.logger.error "LOCK TIMEOUT: Failed to acquire inventory lock for product_id=#{kuralis_product.id}"
      raise InventoryLockError, "Could not acquire inventory lock within #{LOCK_TIMEOUT} seconds"
    rescue => e
      Rails.logger.error "Error in inventory release: #{e.message}"
      raise
    end
  end

  # Manual adjustment with proper locking
  def self.manual_adjustment(kuralis_product:, quantity_change:, notes:, user_id: nil)
    return unless kuralis_product && quantity_change

    # Don't allow adjustments that would make inventory negative
    if kuralis_product.base_quantity + quantity_change < 0
      Rails.logger.warn "Rejected manual inventory adjustment for product_id=#{kuralis_product.id}: Would result in negative inventory"
      return false
    end

    lock_key = "inventory_lock:#{kuralis_product.id}"

    begin
      redis_connection.lock_for_update(lock_key) do
        manual_adjustment_atomic(kuralis_product, quantity_change, notes, user_id)
      end
    rescue Timeout::Error
      Rails.logger.error "LOCK TIMEOUT: Failed to acquire inventory lock for product_id=#{kuralis_product.id}"
      false
    rescue => e
      Rails.logger.error "Error in manual adjustment: #{e.message}"
      false
    end
  end

  # Reconcile inventory across all platforms
  def self.reconcile_inventory(kuralis_product:)
    lock_key = "inventory_lock:#{kuralis_product.id}"

    begin
      redis_connection.lock_for_update(lock_key) do
        InventoryReconciliationService.reconcile_with_platforms(kuralis_product)
      end
    rescue Timeout::Error
      Rails.logger.error "LOCK TIMEOUT: Failed to acquire reconciliation lock for product_id=#{kuralis_product.id}"
      false
    rescue => e
      Rails.logger.error "Error in inventory reconciliation: #{e.message}"
      false
    end
  end

  private

  # Atomic allocation within a database transaction
  def self.allocate_inventory_atomic(kuralis_product, quantity, order, order_item)
    ActiveRecord::Base.transaction do
      # Reload within transaction with lock
      product = KuralisProduct.lock.find(kuralis_product.id)

      # Ensure initial_quantity is set
      ensure_initial_quantity_set(product)

      # Check for existing transaction within lock
      existing_transaction = InventoryTransaction.find_by(
        kuralis_product: product,
        order_item: order_item,
        transaction_type: "allocation"
      )

      if existing_transaction
        Rails.logger.info "Duplicate allocation detected for order_item_id=#{order_item.id}"
        return existing_transaction
      end

      # Check if we have sufficient inventory
      if product.base_quantity < quantity
        # Create failed allocation transaction for tracking
        failed_transaction = InventoryTransaction.create!(
          kuralis_product: product,
          order_item: order_item,
          order: order,
          quantity: -quantity,
          transaction_type: "allocation_failed",
          previous_quantity: product.base_quantity,
          new_quantity: product.base_quantity,
          notes: "Insufficient Inventory: Requested #{quantity}, Available #{product.base_quantity}",
          processed: false
        )

        # Create notification
        create_insufficient_inventory_notification(order, product, quantity)

        # Schedule cross-platform sync for failed transaction (skip originating platform)
        schedule_cross_platform_sync(product, order.platform)

        raise InsufficientInventoryError, "Insufficient inventory: requested #{quantity}, available #{product.base_quantity}"
      end

      # Create successful allocation transaction
      new_quantity = product.base_quantity - quantity
      inventory_transaction = InventoryTransaction.create!(
        kuralis_product: product,
        order_item: order_item,
        order: order,
        quantity: -quantity,
        transaction_type: "allocation",
        previous_quantity: product.base_quantity,
        new_quantity: new_quantity,
        processed: false
      )

      # Update product with new quantity and status
      update_data = {
        base_quantity: new_quantity,
        last_inventory_update: Time.current
      }

      # Mark as out-of-stock if needed
      if new_quantity.zero?
        update_data[:status] = "completed"
      end

      # Prevent the model callback from scheduling duplicate sync
      product.instance_variable_set(:@skip_inventory_sync, true)
      product.update!(update_data)

      # Schedule cross-platform sync (async)
      schedule_cross_platform_sync(product, order.platform)

      inventory_transaction
    end
  end

  # Atomic release within a database transaction
  def self.release_inventory_atomic(kuralis_product, quantity, order, order_item)
    ActiveRecord::Base.transaction do
      # Reload within transaction with lock
      product = KuralisProduct.lock.find(kuralis_product.id)

      # Check for existing transaction
      existing_transaction = InventoryTransaction.find_by(
        kuralis_product: product,
        order_item: order_item,
        transaction_type: "release"
      )

      if existing_transaction
        Rails.logger.info "Duplicate release detected for order_item_id=#{order_item.id}"
        return existing_transaction
      end

      # Create release transaction
      new_quantity = product.base_quantity + quantity
      inventory_transaction = InventoryTransaction.create!(
        kuralis_product: product,
        order_item: order_item,
        order: order,
        quantity: quantity,
        transaction_type: "release",
        previous_quantity: product.base_quantity,
        new_quantity: new_quantity,
        processed: false
      )

      # Prevent the model callback from scheduling duplicate sync
      product.instance_variable_set(:@skip_inventory_sync, true)

      # Update product
      product.update!(
        base_quantity: new_quantity,
        status: "active", # Reactivate when inventory is released
        last_inventory_update: Time.current
      )

      # Schedule cross-platform sync
      schedule_cross_platform_sync(product, order.platform)

      inventory_transaction
    end
  end

  # Atomic manual adjustment
  def self.manual_adjustment_atomic(kuralis_product, quantity_change, notes, user_id)
    ActiveRecord::Base.transaction do
      product = KuralisProduct.lock.find(kuralis_product.id)

      new_quantity = product.base_quantity + quantity_change

      InventoryTransaction.create!(
        kuralis_product: product,
        quantity: quantity_change,
        transaction_type: "manual_adjustment",
        previous_quantity: product.base_quantity,
        new_quantity: new_quantity,
        notes: notes,
        processed: false
      )

      # Update status based on new quantity
      update_data = {
        base_quantity: new_quantity,
        last_inventory_update: Time.current
      }

      if new_quantity.zero? && product.status == "active"
        update_data[:status] = "completed"
      elsif new_quantity.positive? && product.status == "completed"
        update_data[:status] = "active"
      end

      # Prevent the model callback from scheduling duplicate sync
      product.instance_variable_set(:@skip_inventory_sync, true)
      product.update!(update_data)

      # Schedule cross-platform sync (manual adjustments sync all platforms)
      # This is intentional - manual adjustments should update all platforms
      schedule_cross_platform_sync(product, nil)

      true
    end
  end

  # Generate idempotency key for operations
  def self.generate_idempotency_key(order, order_item, operation)
    "#{operation}:#{order.platform}:#{order.platform_order_id}:#{order_item.platform_item_id}:#{order_item.quantity}"
  end

  # Create notification for insufficient inventory
  def self.create_insufficient_inventory_notification(order, product, requested_quantity)
    Notification.create!(
      shop_id: order.shop_id,
      title: "Insufficient Inventory",
      message: "Order ##{order.platform_order_id} requires #{requested_quantity} units of '#{product.title}' but only #{product.base_quantity} available",
      category: "inventory",
      status: "warning",
      metadata: {
        order_id: order.id,
        product_id: product.id,
        requested: requested_quantity,
        available: product.base_quantity,
        platform: order.platform
      }
    )
  end

  # Schedule cross-platform inventory sync with deduplication
  def self.schedule_cross_platform_sync(kuralis_product, skip_platform)
    # Use a unique job key to prevent duplicate jobs for the same product
    job_key = "sync_inventory_#{kuralis_product.id}_#{skip_platform}"

    # Cancel any existing job for this product/platform combo
    Rails.cache.delete("scheduled_job:#{job_key}")

    # Schedule new job with small delay to allow for transaction completion
    job_id = CrossPlatformInventorySyncJob.set(
      wait: 3.seconds,
      queue: "inventory"
    ).perform_later(
      kuralis_product.shop_id,
      kuralis_product.id,
      skip_platform
    )

    # Cache the job ID briefly to prevent duplicates
    Rails.cache.write("scheduled_job:#{job_key}", job_id, expires_in: 30.seconds)

    Rails.logger.info "Scheduled CrossPlatformInventorySyncJob for product_id=#{kuralis_product.id}, skip_platform=#{skip_platform}"
  end

  # Legacy method for backward compatibility
  def self.schedule_inventory_processing(kuralis_product)
    ProcessInventoryTransactionsJob.set(wait: 5.seconds).perform_later(
      kuralis_product.shop_id,
      kuralis_product.id
    )
  end

  # Ensure initial quantity is set
  def self.ensure_initial_quantity_set(kuralis_product)
    if kuralis_product.initial_quantity.nil?
      kuralis_product.update_column(:initial_quantity, kuralis_product.base_quantity)
      Rails.logger.info "Set initial_quantity=#{kuralis_product.base_quantity} for product_id=#{kuralis_product.id}"
    end
  end

  # Calculate expected quantity from transactions
  def self.calculate_expected_quantity(kuralis_product)
    initial_quantity = kuralis_product.initial_quantity || 0
    valid_transaction_types = [ "allocation", "release", "manual_adjustment" ]

    transaction_total = kuralis_product.inventory_transactions
                                      .where(transaction_type: valid_transaction_types)
                                      .sum(:quantity)

    [ initial_quantity + transaction_total, 0 ].max
  end
end
