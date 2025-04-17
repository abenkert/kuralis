class InventoryService
  class InsufficientInventoryError < StandardError; end
  class InventoryLockError < StandardError; end

  # Maximum time to wait for a lock before giving up (in seconds)
  LOCK_TIMEOUT = 10

  def self.allocate_inventory(kuralis_product:, quantity:, order:, order_item:)
    return unless kuralis_product && quantity && order && order_item

    # Ensure initial_quantity is set to prevent reconciliation issues
    ensure_initial_quantity_set(kuralis_product)

    # Check if we already have a transaction for this order item
    existing_transaction = InventoryTransaction.find_by(
      kuralis_product: kuralis_product,
      order_item: order_item,
      transaction_type: "allocation"
    )

    if existing_transaction
      Rails.logger.info "Skipping duplicate allocation for order_item_id=#{order_item.id}, product_id=#{kuralis_product.id}"
      return existing_transaction
    end

    Rails.logger.info "Allocating inventory for order_id=#{order.id}, product_id=#{kuralis_product.id}, quantity=#{quantity}"

    begin
      # Use a timeout to prevent deadlocks
      Timeout.timeout(LOCK_TIMEOUT) do
        kuralis_product.with_lock do
          # Double-check after acquiring lock (prevent race conditions)
          if InventoryTransaction.exists?(
            kuralis_product: kuralis_product,
            order_item: order_item,
            transaction_type: "allocation"
          )
            Rails.logger.info "Race condition detected: Another process already allocated for order_item_id=#{order_item.id}"
            return
          end

          if kuralis_product.base_quantity >= quantity
            inventory_transaction = InventoryTransaction.create!(
              kuralis_product: kuralis_product,
              order_item: order_item,
              order: order,
              quantity: -quantity,
              transaction_type: "allocation",
              previous_quantity: kuralis_product.base_quantity,
              new_quantity: kuralis_product.base_quantity - quantity
            )

            # Save current time for tracking inventory change timing
            update_data = {
              base_quantity: inventory_transaction.new_quantity,
              last_inventory_update: Time.current
            }

            # Mark as out-of-stock if needed
            if inventory_transaction.new_quantity.zero?
              update_data[:status] = "completed"
            end

            kuralis_product.update!(update_data)

            # Return the transaction for potential future use
            inventory_transaction
          else
            # Record the failed allocation attempt with details
            inventory_transaction = InventoryTransaction.create!(
              kuralis_product: kuralis_product,
              order_item: order_item,
              order: order,
              quantity: -quantity,
              transaction_type: "allocation_failed",
              previous_quantity: kuralis_product.base_quantity,
              new_quantity: kuralis_product.base_quantity,
              notes: "Insufficient Inventory: Requested #{quantity}, Available #{kuralis_product.base_quantity}"
            )

            # Create notification for store owner
            Notification.create!(
              shop_id: order.shop_id,
              title: "Insufficient Inventory",
              message: "Order ##{order.platform_order_id} requires #{quantity} units of '#{kuralis_product.title}' but only #{kuralis_product.base_quantity} available",
              category: "inventory",
              status: "warning",
              metadata: {
                order_id: order.id,
                product_id: kuralis_product.id,
                requested: quantity,
                available: kuralis_product.base_quantity
              }
            )

            # Return the failed transaction
            inventory_transaction
          end
        end
      end
    rescue Timeout::Error
      Rails.logger.error "LOCK TIMEOUT: Failed to acquire lock for product_id=#{kuralis_product.id} after #{LOCK_TIMEOUT} seconds"

      # Create a notification about the lock timeout
      Notification.create!(
        shop_id: order.shop_id,
        title: "Inventory System Warning",
        message: "Failed to process inventory for product '#{kuralis_product.title}' due to database contention",
        category: "system",
        status: "error",
        metadata: {
          order_id: order.id,
          product_id: kuralis_product.id,
          error: "lock_timeout"
        }
      )

      raise InventoryLockError, "Failed to acquire lock for product_id=#{kuralis_product.id}"
    end
  end

  def self.release_inventory(kuralis_product:, quantity:, order:, order_item:)
    return unless kuralis_product && quantity && order && order_item

    # Ensure initial_quantity is set to prevent reconciliation issues
    ensure_initial_quantity_set(kuralis_product)

    # Check if we already have a transaction for this order item
    existing_transaction = InventoryTransaction.find_by(
      kuralis_product: kuralis_product,
      order_item: order_item,
      transaction_type: "release"
    )

    if existing_transaction
      Rails.logger.info "Skipping duplicate release for order_item_id=#{order_item.id}, product_id=#{kuralis_product.id}"
      return existing_transaction
    end

    Rails.logger.info "Releasing inventory for order_id=#{order.id}, product_id=#{kuralis_product.id}, quantity=#{quantity}"

    begin
      # Use a timeout to prevent deadlocks
      Timeout.timeout(LOCK_TIMEOUT) do
        kuralis_product.with_lock do
          # Double-check after acquiring lock (prevent race conditions)
          if InventoryTransaction.exists?(
            kuralis_product: kuralis_product,
            order_item: order_item,
            transaction_type: "release"
          )
            Rails.logger.info "Race condition detected: Another process already released for order_item_id=#{order_item.id}"
            return
          end

          inventory_transaction = InventoryTransaction.create!(
            kuralis_product: kuralis_product,
            order_item: order_item,
            order: order,
            quantity: quantity,
            transaction_type: "release",
            previous_quantity: kuralis_product.base_quantity,
            new_quantity: kuralis_product.base_quantity + quantity
          )

          # Always update last_inventory_update for tracking
          kuralis_product.update!(
            base_quantity: inventory_transaction.new_quantity,
            status: "active",
            last_inventory_update: Time.current
          )

          # Return the transaction for potential future use
          inventory_transaction
        end
      end
    rescue Timeout::Error
      Rails.logger.error "LOCK TIMEOUT: Failed to acquire lock for product_id=#{kuralis_product.id} after #{LOCK_TIMEOUT} seconds"

      # Create a notification about the lock timeout
      Notification.create!(
        shop_id: order.shop_id,
        title: "Inventory System Warning",
        message: "Failed to release inventory for product '#{kuralis_product.title}' due to database contention",
        category: "system",
        status: "error",
        metadata: {
          order_id: order.id,
          product_id: kuralis_product.id,
          error: "lock_timeout"
        }
      )

      raise InventoryLockError, "Failed to acquire lock for product_id=#{kuralis_product.id}"
    end
  end

  def self.reconcile_inventory(kuralis_product:)
    return unless kuralis_product

    # Ensure initial_quantity is set
    ensure_initial_quantity_set(kuralis_product)

    Rails.logger.info "Starting inventory reconciliation for product_id=#{kuralis_product.id}"

    begin
      # Use a timeout to prevent deadlocks
      Timeout.timeout(LOCK_TIMEOUT) do
        kuralis_product.with_lock do
          # Calculate expected inventory based on initial quantity and all transactions
          expected_quantity = calculate_expected_quantity(kuralis_product)
          current_quantity = kuralis_product.base_quantity

          if expected_quantity != current_quantity
            # Record the discrepancy details
            discrepancy = expected_quantity - current_quantity

            InventoryTransaction.create!(
              kuralis_product: kuralis_product,
              quantity: discrepancy,
              transaction_type: "reconciliation",
              previous_quantity: current_quantity,
              new_quantity: expected_quantity,
              notes: "Inventory reconciliation adjustment: #{discrepancy > 0 ? 'Added' : 'Removed'} #{discrepancy.abs} units"
            )

            # Update with the reconciled quantity
            kuralis_product.update!(
              base_quantity: expected_quantity,
              last_inventory_update: Time.current
            )

            # Notify store owner of significant discrepancies
            if discrepancy.abs >= 5 # Threshold for notification
              Notification.create!(
                shop_id: kuralis_product.shop_id,
                title: "Inventory Reconciliation",
                message: "Significant inventory discrepancy detected for '#{kuralis_product.title}'. #{discrepancy > 0 ? 'Added' : 'Removed'} #{discrepancy.abs} units.",
                category: "inventory",
                status: "info",
                metadata: {
                  product_id: kuralis_product.id,
                  previous: current_quantity,
                  current: expected_quantity,
                  discrepancy: discrepancy
                }
              )
            end

            Rails.logger.info "Reconciled inventory for product_id=#{kuralis_product.id}: #{current_quantity} → #{expected_quantity} (Δ#{discrepancy})"
          else
            Rails.logger.info "No reconciliation needed for product_id=#{kuralis_product.id}, inventory correct at #{current_quantity}"
          end
        end
      end
    rescue Timeout::Error
      Rails.logger.error "LOCK TIMEOUT: Failed to acquire lock for reconciliation of product_id=#{kuralis_product.id}"

      # Create a notification about the lock timeout
      Notification.create!(
        shop_id: kuralis_product.shop_id,
        title: "Inventory System Warning",
        message: "Failed to reconcile inventory for product '#{kuralis_product.title}' due to database contention",
        category: "system",
        status: "error",
        metadata: {
          product_id: kuralis_product.id,
          error: "lock_timeout"
        }
      )
    end
  end

  # New method to handle manual inventory adjustments by store owner
  def self.manual_adjustment(kuralis_product:, quantity_change:, notes:, user_id: nil)
    return unless kuralis_product && quantity_change

    # Don't allow adjustments that would make inventory negative
    if kuralis_product.base_quantity + quantity_change < 0
      Rails.logger.warn "Rejected manual inventory adjustment for product_id=#{kuralis_product.id}: Would result in negative inventory"
      return false
    end

    begin
      Timeout.timeout(LOCK_TIMEOUT) do
        kuralis_product.with_lock do
          InventoryTransaction.create!(
            kuralis_product: kuralis_product,
            quantity: quantity_change,
            transaction_type: "manual_adjustment",
            previous_quantity: kuralis_product.base_quantity,
            new_quantity: kuralis_product.base_quantity + quantity_change,
            notes: notes,
            metadata: { user_id: user_id }
          )

          new_quantity = kuralis_product.base_quantity + quantity_change

          # Update the product with new quantity and appropriate status
          update_data = {
            base_quantity: new_quantity,
            last_inventory_update: Time.current
          }

          # Update status based on new quantity
          if new_quantity.zero? && kuralis_product.status == "active"
            update_data[:status] = "completed"
          elsif new_quantity.positive? && kuralis_product.status == "completed"
            update_data[:status] = "active"
          end

          kuralis_product.update!(update_data)

          true
        end
      end
    rescue Timeout::Error
      Rails.logger.error "LOCK TIMEOUT: Failed to perform manual adjustment for product_id=#{kuralis_product.id}"
      false
    end
  end

  private

  def self.ensure_initial_quantity_set(kuralis_product)
    # If initial_quantity isn't set, set it to the current base_quantity
    if kuralis_product.initial_quantity.nil?
      kuralis_product.update_column(:initial_quantity, kuralis_product.base_quantity)
      Rails.logger.info "Set initial_quantity=#{kuralis_product.base_quantity} for product_id=#{kuralis_product.id}"
    end
  end

  def self.calculate_expected_quantity(kuralis_product)
    initial_quantity = kuralis_product.initial_quantity || 0

    # We need to filter by successful transaction types, excluding failed attempts and reconciliations
    valid_transaction_types = [ "allocation", "release", "manual_adjustment" ]

    # Calculate total from all valid transactions
    transaction_total = kuralis_product.inventory_transactions
                                      .where(transaction_type: valid_transaction_types)
                                      .sum(:quantity)

    # Initial quantity + all transaction changes
    [ initial_quantity + transaction_total, 0 ].max # Ensure we never calculate negative inventory
  end
end
