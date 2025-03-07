class InventoryService
  class InsufficientInventoryError < StandardError; end

  def self.allocate_inventory(kuralis_product:, quantity:, order:, order_item:)
    p "Allocating inventory for #{order.id}"
    
    # Check if we already have a transaction for this order item
    return if InventoryTransaction.exists?(
      kuralis_product: kuralis_product,
      order_item: order_item,
      transaction_type: 'allocation'
    )

    kuralis_product.with_lock do
      if kuralis_product.base_quantity >= quantity
        inventory_transaction = InventoryTransaction.create!(
          kuralis_product: kuralis_product,
          order_item: order_item,
          order: order,
          quantity: -quantity,
          transaction_type: 'allocation',
          previous_quantity: kuralis_product.base_quantity,
          new_quantity: kuralis_product.base_quantity - quantity
        )
        kuralis_product.update!(
          base_quantity: inventory_transaction.new_quantity,
          status: inventory_transaction.new_quantity.zero? ? 'completed' : kuralis_product.status
        )
      else
        inventory_transaction = InventoryTransaction.create!(
          kuralis_product: kuralis_product,
          order_item: order_item,
          order: order,
          quantity: -quantity,
          transaction_type: 'allocation',
          previous_quantity: kuralis_product.base_quantity,
          new_quantity: kuralis_product.base_quantity - quantity,
          notes: 'Insufficient Inventory for Order Kuralis Product has not been updated'
        )

        Notification.create!(
          shop_id: order.shop_id,
          title: 'Insufficient Inventory',
          message: "Insufficient inventory for product #{kuralis_product.id}",
          category: 'inventory',
          status: 'warning',
          metadata: { order_id: order.id, product_id: kuralis_product.id }
        )
        # raise InsufficientInventoryError, "Insufficient inventory for product #{kuralis_product.id}"
      end
    end
  end

  def self.release_inventory(kuralis_product:, quantity:, order:, order_item:)
    # Check if we already have a transaction for this order item
    return if InventoryTransaction.exists?(
      kuralis_product: kuralis_product,
      order_item: order_item,
      transaction_type: 'release'
    )

    kuralis_product.with_lock do
      inventory_transaction = InventoryTransaction.create!(
        kuralis_product: kuralis_product,
        order_item: order_item,
        order: order,
        quantity: quantity,
        transaction_type: 'release',
        previous_quantity: kuralis_product.base_quantity,
        new_quantity: kuralis_product.base_quantity + quantity
      )

      kuralis_product.update!(
        base_quantity: inventory_transaction.new_quantity,
        status: 'active'
      )
    end
  end

  def self.reconcile_inventory(kuralis_product:)
    kuralis_product.with_lock do
      # Calculate expected inventory based on initial quantity and all transactions
      expected_quantity = calculate_expected_quantity(kuralis_product)
      
      if expected_quantity != kuralis_product.base_quantity
        InventoryTransaction.create!(
          kuralis_product: kuralis_product,
          quantity: expected_quantity - kuralis_product.base_quantity,
          transaction_type: 'reconciliation',
          previous_quantity: kuralis_product.base_quantity,
          new_quantity: expected_quantity,
          notes: "Inventory reconciliation adjustment"
        )

        kuralis_product.update!(base_quantity: expected_quantity)
      end
    end
  end

  private

  def self.calculate_expected_quantity(kuralis_product)
    initial_quantity = kuralis_product.initial_quantity
    total_allocated = kuralis_product.inventory_transactions.where(transaction_type: 'allocation').sum(:quantity)
    total_released = kuralis_product.inventory_transactions.where(transaction_type: 'release').sum(:quantity)
    
    initial_quantity + total_allocated + total_released
  end
end 