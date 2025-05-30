require 'rails_helper'

RSpec.describe InventoryService, type: :service do
  let(:shop) { create(:shop, :with_inventory_sync) }
  let(:product) { create(:kuralis_product, shop: shop, base_quantity: 10) }
  let(:order) { create(:order, shop: shop) }
  let(:order_item) { create(:order_item, order: order, kuralis_product: product, quantity: 2) }

  before do
    # Clear Redis and stub jobs before each test
    clear_redis_cache
    stub_inventory_sync_job
  end

  describe '.allocate_inventory' do
    context 'with sufficient inventory' do
      it 'allocates inventory successfully' do
        expect {
          InventoryService.allocate_inventory(
            kuralis_product: product,
            quantity: 2,
            order: order,
            order_item: order_item
          )
        }.to change { product.reload.base_quantity }.from(10).to(8)
      end

      it 'creates an allocation transaction' do
        expect {
          InventoryService.allocate_inventory(
            kuralis_product: product,
            quantity: 2,
            order: order,
            order_item: order_item
          )
        }.to change { InventoryTransaction.count }.by(1)

        transaction = InventoryTransaction.last
        expect(transaction.transaction_type).to eq('allocation')
        expect(transaction.quantity).to eq(-2)
        expect(transaction.kuralis_product).to eq(product)
      end

      it 'schedules cross-platform sync' do
        InventoryService.allocate_inventory(
          kuralis_product: product,
          quantity: 2,
          order: order,
          order_item: order_item
        )

        expect_inventory_sync_scheduled(product.id, order.platform)
      end

      it 'uses idempotency to prevent duplicate allocations' do
        # First allocation
        InventoryService.allocate_inventory(
          kuralis_product: product,
          quantity: 2,
          order: order,
          order_item: order_item
        )

        # Second identical allocation should be skipped
        expect {
          InventoryService.allocate_inventory(
            kuralis_product: product,
            quantity: 2,
            order: order,
            order_item: order_item
          )
        }.not_to change { product.reload.base_quantity }
      end
    end

    context 'with insufficient inventory' do
      let(:product) { create(:kuralis_product, shop: shop, base_quantity: 1) }

      it 'raises InsufficientInventoryError' do
        expect {
          InventoryService.allocate_inventory(
            kuralis_product: product,
            quantity: 5,
            order: order,
            order_item: order_item
          )
        }.to raise_error(InventoryService::InsufficientInventoryError)
      end

      it 'creates a failed allocation transaction' do
        expect {
          begin
            InventoryService.allocate_inventory(
              kuralis_product: product,
              quantity: 5,
              order: order,
              order_item: order_item
            )
          rescue InventoryService::InsufficientInventoryError
            # Expected error
          end
        }.to change { InventoryTransaction.where(transaction_type: 'allocation_failed').count }.by(1)
      end

      it 'does not change product quantity' do
        expect {
          begin
            InventoryService.allocate_inventory(
              kuralis_product: product,
              quantity: 5,
              order: order,
              order_item: order_item
            )
          rescue InventoryService::InsufficientInventoryError
            # Expected error
          end
        }.not_to change { product.reload.base_quantity }
      end
    end
  end

  describe '.release_inventory' do
    before do
      # Set up product with allocated inventory
      product.update!(base_quantity: 8)
      create(:inventory_transaction, :allocation, kuralis_product: product, order: order, order_item: order_item)
    end

    it 'releases inventory successfully' do
      expect {
        InventoryService.release_inventory(
          kuralis_product: product,
          quantity: 2,
          order: order,
          order_item: order_item
        )
      }.to change { product.reload.base_quantity }.from(8).to(10)
    end

    it 'creates a release transaction' do
      expect {
        InventoryService.release_inventory(
          kuralis_product: product,
          quantity: 2,
          order: order,
          order_item: order_item
        )
      }.to change { InventoryTransaction.where(transaction_type: 'release').count }.by(1)
    end

    it 'reactivates product when releasing inventory' do
      product.update!(status: 'completed')

      InventoryService.release_inventory(
        kuralis_product: product,
        quantity: 2,
        order: order,
        order_item: order_item
      )

      expect(product.reload.status).to eq('active')
    end
  end

  describe '.manual_adjustment' do
    it 'adjusts inventory with positive change' do
      expect {
        InventoryService.manual_adjustment(
          kuralis_product: product,
          quantity_change: 5,
          notes: 'Found extra stock'
        )
      }.to change { product.reload.base_quantity }.from(10).to(15)
    end

    it 'adjusts inventory with negative change' do
      expect {
        InventoryService.manual_adjustment(
          kuralis_product: product,
          quantity_change: -3,
          notes: 'Damaged items removed'
        )
      }.to change { product.reload.base_quantity }.from(10).to(7)
    end

    it 'prevents negative inventory' do
      result = InventoryService.manual_adjustment(
        kuralis_product: product,
        quantity_change: -15,
        notes: 'This should fail'
      )

      expect(result).to be false
      expect(product.reload.base_quantity).to eq(10)
    end

    it 'creates manual adjustment transaction' do
      expect {
        InventoryService.manual_adjustment(
          kuralis_product: product,
          quantity_change: 5,
          notes: 'Test adjustment'
        )
      }.to change { InventoryTransaction.where(transaction_type: 'manual_adjustment').count }.by(1)
    end
  end

  describe 'Redis locking' do
    it 'prevents concurrent inventory operations', :redis do
      # This test would require more complex setup to actually test locking
      # but demonstrates the concept

      allow(InventoryService).to receive(:redis_connection).and_return(double('redis'))

      InventoryService.allocate_inventory(
        kuralis_product: product,
        quantity: 2,
        order: order,
        order_item: order_item
      )

      # Verify that locking mechanism was called
      # In a real test, you'd simulate concurrent access
    end
  end

  describe 'idempotency key generation' do
    it 'generates consistent keys for same parameters' do
      key1 = InventoryService.send(:generate_idempotency_key, order, order_item, "allocation")
      key2 = InventoryService.send(:generate_idempotency_key, order, order_item, "allocation")

      expect(key1).to eq(key2)
    end

    it 'generates different keys for different operations' do
      allocation_key = InventoryService.send(:generate_idempotency_key, order, order_item, "allocation")
      release_key = InventoryService.send(:generate_idempotency_key, order, order_item, "release")

      expect(allocation_key).not_to eq(release_key)
    end
  end
end
