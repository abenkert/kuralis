# Inventory testing helpers
module InventoryHelpers
  def expect_inventory_allocation(product, quantity, order, order_item)
    expect(InventoryService).to receive(:allocate_inventory).with(
      kuralis_product: product,
      quantity: quantity,
      order: order,
      order_item: order_item
    )
  end

  def expect_inventory_release(product, quantity, order, order_item)
    expect(InventoryService).to receive(:release_inventory).with(
      kuralis_product: product,
      quantity: quantity,
      order: order,
      order_item: order_item
    )
  end

  def create_inventory_transaction(product, quantity, transaction_type, options = {})
    InventoryTransaction.create!(
      kuralis_product: product,
      quantity: quantity,
      transaction_type: transaction_type,
      previous_quantity: options[:previous_quantity] || product.base_quantity,
      new_quantity: options[:new_quantity] || (product.base_quantity + quantity),
      order: options[:order],
      order_item: options[:order_item],
      notes: options[:notes],
      processed: options[:processed] || false
    )
  end

  def stub_inventory_sync_job
    allow(ProcessInventoryTransactionsJob).to receive(:perform_later)
    allow(CrossPlatformInventorySyncJob).to receive(:perform_later)
  end

  def expect_inventory_sync_scheduled(product_id, skip_platform = nil)
    expect(CrossPlatformInventorySyncJob).to have_received(:perform_later)
      .with(anything, product_id, skip_platform)
  end

  def stub_platform_inventory_updates
    # Stub eBay inventory updates
    allow_any_instance_of(Ebay::InventoryService).to receive(:update_inventory).and_return(true)

    # Stub Shopify inventory updates
    allow_any_instance_of(Shopify::InventoryService).to receive(:update_inventory).and_return(true)
  end

  def expect_sufficient_inventory(product, required_quantity)
    expect(product.base_quantity).to be >= required_quantity
  end

  def expect_insufficient_inventory(product, required_quantity)
    expect(product.base_quantity).to be < required_quantity
  end
end

RSpec.configure do |config|
  config.include InventoryHelpers
end
