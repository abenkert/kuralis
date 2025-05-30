require 'rails_helper'

RSpec.describe OrderProcessingService, type: :service do
  let(:shop) { create(:shop, :with_inventory_sync) }
  let(:ebay_account) { create(:shopify_ebay_account, shop: shop) }
  let(:product) { create(:kuralis_product, :with_ebay_listing, shop: shop, base_quantity: 10) }
  let(:ebay_listing) { product.ebay_listing }

  let(:base_order_data) do
    {
      "orderId" => "22-13122-69491",
      "creationDate" => Time.current.iso8601,
      "orderFulfillmentStatus" => "NOT_STARTED",
      "orderPaymentStatus" => "PAID",
      "pricingSummary" => {
        "priceSubtotal" => { "value" => "19.99" },
        "total" => { "value" => "24.99" },
        "deliveryCost" => { "value" => "5.00" }
      },
      "paymentSummary" => {
        "payments" => [
          {
            "paymentDate" => 1.hour.ago.iso8601,
            "paymentMethod" => "PayPal"
          }
        ]
      },
      "buyer" => {
        "username" => "testbuyer123"
      },
      "fulfillmentStartInstructions" => [
        {
          "shippingStep" => {
            "shipTo" => {
              "fullName" => "John Doe",
              "contactAddress" => {
                "addressLine1" => "123 Test St",
                "addressLine2" => "Apt 4B",
                "city" => "Test City",
                "stateOrProvince" => "CA",
                "postalCode" => "12345",
                "countryCode" => "US"
              }
            }
          }
        }
      ],
      "lineItems" => [
        {
          "legacyItemId" => ebay_listing.ebay_item_id,
          "title" => "Test Product",
          "quantity" => 1
        }
      ]
    }
  end

  before do
    clear_redis_cache
    stub_inventory_sync_job
  end

  describe 'cancelled order scenarios' do
    context 'when order is cancelled before inventory sync' do
      it 'does not adjust inventory for pre-sync cancellations' do
        # Set up timeline:
        # 1. Order placed on 2025-05-22
        # 2. Order cancelled on 2025-05-23 (eBay automatically restores inventory)
        # 3. eBay listing synced on 2025-05-24 (we capture the restored inventory state)
        # 4. We sync orders on 2025-05-26 (we see the cancelled order for first time)
        ebay_listing.update!(last_sync_at: Date.new(2025, 5, 24))

        cancelled_order_data = base_order_data.merge(
          "creationDate" => Date.new(2025, 5, 22).iso8601,
          "orderFulfillmentStatus" => "CANCELLED",
          "cancelStatus" => {
            "cancelState" => "CANCELED",
            "cancelDate" => Date.new(2025, 5, 23).iso8601,
            "cancelReason" => "Buyer requested cancellation"
          }
        )

        # Process the order (simulating order sync on 2025-05-26)
        service = OrderProcessingService.new(cancelled_order_data, "ebay", shop)
        result = service.process_with_idempotency

        # Should NOT adjust inventory because:
        # - Order was cancelled BEFORE last inventory sync (2025-05-23 < 2025-05-24)
        # - Our inventory sync already captured the restored state after cancellation

        expect(result[:success]).to be true
        expect(product.reload.base_quantity).to eq(10) # No change
        expect(InventoryTransaction.where(kuralis_product: product).count).to eq(0)
      end
    end

    context 'when order is cancelled after inventory sync' do
      it 'releases inventory for post-sync cancellations' do
        # Set up timeline:
        # 1. eBay listing synced on 2025-05-21 (baseline inventory captured)
        # 2. Order placed on 2025-05-22 (eBay reduces inventory automatically)
        # 3. Order cancelled on 2025-05-24 (eBay restores inventory automatically)
        # 4. We sync orders on 2025-05-26 (we see the cancelled order for first time)

        # Our system needs to:
        # - Recognize the order was placed after our sync (should allocate normally)
        # - But also recognize it was cancelled after our sync (should release)
        # - Net effect: release inventory to match eBay's current restored state

        ebay_listing.update!(last_sync_at: Date.new(2025, 5, 21))

        cancelled_order_data = base_order_data.merge(
          "creationDate" => Date.new(2025, 5, 22).iso8601,
          "orderFulfillmentStatus" => "CANCELLED",
          "cancelStatus" => {
            "cancelState" => "CANCELED",
            "cancelDate" => Date.new(2025, 5, 24).iso8601,
            "cancelReason" => "Buyer requested cancellation"
          }
        )

        # Process the order (simulating order sync on 2025-05-26)
        service = OrderProcessingService.new(cancelled_order_data, "ebay", shop)
        result = service.process_with_idempotency

        # Should release inventory because:
        # - Order was placed after last inventory sync (2025-05-22 > 2025-05-21) ✓
        # - Order was cancelled after last inventory sync (2025-05-24 > 2025-05-21) ✓
        # - So we need to release inventory to match eBay's restored state

        expect(result[:success]).to be true
        expect(product.reload.base_quantity).to eq(11) # Released 1 unit

        transaction = InventoryTransaction.where(kuralis_product: product).first
        expect(transaction.transaction_type).to eq('release')
        expect(transaction.quantity).to eq(1)
      end
    end

    context 'when active order should allocate inventory' do
      it 'allocates inventory for orders placed after sync' do
        # Set up timeline:
        # 1. eBay listing synced on 2025-05-20
        ebay_listing.update!(last_sync_at: Date.new(2025, 5, 20))

        # 2. Order placed on 2025-05-22 (after sync, active order)
        active_order_data = base_order_data.merge(
          "creationDate" => Date.new(2025, 5, 22).iso8601,
          "orderFulfillmentStatus" => "NOT_STARTED"
        )

        # Process the order
        service = OrderProcessingService.new(active_order_data, "ebay", shop)
        result = service.process_with_idempotency

        # Should allocate inventory because:
        # - Order was placed after last_sync (2025-05-22 > 2025-05-20) ✓
        # - Order is not cancelled ✓

        expect(result[:success]).to be true
        expect(product.reload.base_quantity).to eq(9) # Allocated 1 unit

        transaction = InventoryTransaction.where(kuralis_product: product).first
        expect(transaction.transaction_type).to eq('allocation')
        expect(transaction.quantity).to eq(-1)
      end
    end

    context 'when order is too old relative to sync' do
      it 'does not adjust inventory for pre-sync orders' do
        # Set up timeline:
        # 1. Order placed on 2025-05-18 (before sync)
        # 2. eBay listing synced on 2025-05-20 (captured current state)
        ebay_listing.update!(last_sync_at: Date.new(2025, 5, 20))

        old_order_data = base_order_data.merge(
          "creationDate" => Date.new(2025, 5, 18).iso8601,
          "orderFulfillmentStatus" => "NOT_STARTED"
        )

        # Process the order
        service = OrderProcessingService.new(old_order_data, "ebay", shop)
        result = service.process_with_idempotency

        # Should NOT adjust inventory because:
        # - Order was placed before last_sync (2025-05-18 < 2025-05-20)
        # - Our inventory sync already captured the state after this order

        expect(result[:success]).to be true
        expect(product.reload.base_quantity).to eq(10) # No change
        expect(InventoryTransaction.where(kuralis_product: product).count).to eq(0)
      end
    end
  end

  describe 'idempotency' do
    it 'prevents duplicate processing of the same order' do
      order_data = base_order_data.merge(
        "creationDate" => Date.new(2025, 5, 22).iso8601,
        "orderFulfillmentStatus" => "NOT_STARTED"
      )

      ebay_listing.update!(last_sync_at: Date.new(2025, 5, 20))

      # Process order twice
      service1 = OrderProcessingService.new(order_data, "ebay", shop)
      result1 = service1.process_with_idempotency

      service2 = OrderProcessingService.new(order_data, "ebay", shop)
      result2 = service2.process_with_idempotency

      # Should only allocate inventory once
      expect(product.reload.base_quantity).to eq(9) # Only allocated once
      expect(InventoryTransaction.where(kuralis_product: product).count).to eq(1)
    end
  end
end
