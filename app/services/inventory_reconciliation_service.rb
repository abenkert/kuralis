class InventoryReconciliationService
  class ReconciliationError < StandardError; end

  # Threshold for significant discrepancies that require notifications
  SIGNIFICANT_DISCREPANCY_THRESHOLD = 5

  def self.reconcile_with_platforms(kuralis_product)
    new(kuralis_product).reconcile
  end

  def initialize(kuralis_product)
    @kuralis_product = kuralis_product
    @shop = kuralis_product.shop
    @discrepancies = []
    @corrections_made = []
  end

  def reconcile
    Rails.logger.info "Starting inventory reconciliation for product_id=#{@kuralis_product.id}"

    # Step 1: Reconcile internal inventory based on transactions
    reconcile_internal_inventory

    # Step 2: Check for platform discrepancies
    check_platform_discrepancies

    # Step 3: Apply corrections if needed
    apply_corrections if @discrepancies.any?

    # Step 4: Create notifications for significant issues
    create_reconciliation_notifications if should_notify?

    # Return reconciliation summary
    {
      success: @discrepancies.empty?,
      discrepancies: @discrepancies,
      corrections: @corrections_made,
      product_id: @kuralis_product.id
    }
  end

  private

  def reconcile_internal_inventory
    # Ensure initial_quantity is set
    if @kuralis_product.initial_quantity.nil?
      @kuralis_product.update_column(:initial_quantity, @kuralis_product.base_quantity)
      Rails.logger.info "Set initial_quantity=#{@kuralis_product.base_quantity} for product_id=#{@kuralis_product.id}"
    end

    # Calculate expected quantity based on transactions
    expected_quantity = calculate_expected_quantity
    current_quantity = @kuralis_product.base_quantity

    if expected_quantity != current_quantity
      discrepancy = expected_quantity - current_quantity

      # Record the internal discrepancy
      @discrepancies << {
        type: "internal",
        expected: expected_quantity,
        actual: current_quantity,
        difference: discrepancy,
        platform: "kuralis"
      }

      # Create reconciliation transaction
      InventoryTransaction.create!(
        kuralis_product: @kuralis_product,
        quantity: discrepancy,
        transaction_type: "reconciliation",
        previous_quantity: current_quantity,
        new_quantity: expected_quantity,
        notes: "Internal inventory reconciliation: #{discrepancy > 0 ? 'Added' : 'Removed'} #{discrepancy.abs} units",
        processed: false
      )

      # Update the product with reconciled quantity
      @kuralis_product.update!(
        base_quantity: expected_quantity,
        last_inventory_update: Time.current
      )

      @corrections_made << {
        type: "internal",
        from: current_quantity,
        to: expected_quantity,
        difference: discrepancy
      }

      Rails.logger.info "Internal inventory reconciled for product_id=#{@kuralis_product.id}: #{current_quantity} → #{expected_quantity} (Δ#{discrepancy})"
    end
  end

  def check_platform_discrepancies
    # Check Shopify discrepancy
    if @kuralis_product.shopify_product.present?
      shopify_quantity = fetch_shopify_quantity
      if shopify_quantity != @kuralis_product.base_quantity
        @discrepancies << {
          type: "platform",
          platform: "shopify",
          expected: @kuralis_product.base_quantity,
          actual: shopify_quantity,
          difference: @kuralis_product.base_quantity - shopify_quantity
        }
      end
    end

    # Check eBay discrepancy
    if @kuralis_product.ebay_listing.present?
      ebay_quantity = fetch_ebay_quantity
      if ebay_quantity != @kuralis_product.base_quantity
        @discrepancies << {
          type: "platform",
          platform: "ebay",
          expected: @kuralis_product.base_quantity,
          actual: ebay_quantity,
          difference: @kuralis_product.base_quantity - ebay_quantity
        }
      end
    end
  end

  def apply_corrections
    platform_discrepancies = @discrepancies.select { |d| d[:type] == "platform" }

    platform_discrepancies.each do |discrepancy|
      case discrepancy[:platform]
      when "shopify"
        correct_shopify_inventory(discrepancy)
      when "ebay"
        correct_ebay_inventory(discrepancy)
      end
    end
  end

  def correct_shopify_inventory(discrepancy)
    begin
      service = Shopify::InventoryService.new(
        @kuralis_product.shopify_product,
        @kuralis_product
      )

      if service.update_inventory
        @corrections_made << {
          type: "platform",
          platform: "shopify",
          from: discrepancy[:actual],
          to: discrepancy[:expected],
          difference: discrepancy[:difference]
        }
        Rails.logger.info "Corrected Shopify inventory for product_id=#{@kuralis_product.id}"
      else
        Rails.logger.error "Failed to correct Shopify inventory for product_id=#{@kuralis_product.id}"
      end
    rescue => e
      Rails.logger.error "Error correcting Shopify inventory: #{e.message}"
    end
  end

  def correct_ebay_inventory(discrepancy)
    begin
      service = Ebay::InventoryService.new(
        @kuralis_product.ebay_listing,
        @kuralis_product
      )

      if service.update_inventory
        @corrections_made << {
          type: "platform",
          platform: "ebay",
          from: discrepancy[:actual],
          to: discrepancy[:expected],
          difference: discrepancy[:difference]
        }
        Rails.logger.info "Corrected eBay inventory for product_id=#{@kuralis_product.id}"
      else
        Rails.logger.error "Failed to correct eBay inventory for product_id=#{@kuralis_product.id}"
      end
    rescue => e
      Rails.logger.error "Error correcting eBay inventory: #{e.message}"
    end
  end

  def fetch_shopify_quantity
    begin
      # Try to get quantity from Shopify API
      client = ShopifyAPI::Clients::Graphql::Admin.new(session: @shop.shopify_session)

      response = client.query(
        query: shopify_inventory_query,
        variables: { id: @kuralis_product.shopify_product.gid }
      )

      if response.body["data"] && response.body["data"]["product"]
        variant = response.body["data"]["product"]["variants"]["edges"].first
        if variant
          return variant["node"]["inventoryQuantity"] || 0
        end
      end

      # Fallback to cached value
      @kuralis_product.shopify_product.quantity || 0
    rescue => e
      Rails.logger.error "Error fetching Shopify quantity: #{e.message}"
      # Return cached value on error
      @kuralis_product.shopify_product.quantity || 0
    end
  end

  def fetch_ebay_quantity
    begin
      # For eBay, we'll use the cached value since real-time API calls are expensive
      # and the eBay sync jobs should keep this updated
      @kuralis_product.ebay_listing.quantity || 0
    rescue => e
      Rails.logger.error "Error fetching eBay quantity: #{e.message}"
      0
    end
  end

  def calculate_expected_quantity
    initial_quantity = @kuralis_product.initial_quantity || 0
    valid_transaction_types = [ "allocation", "release", "manual_adjustment" ]

    transaction_total = @kuralis_product.inventory_transactions
                                        .where(transaction_type: valid_transaction_types)
                                        .sum(:quantity)

    [ initial_quantity + transaction_total, 0 ].max
  end

  def should_notify?
    # Notify if there are significant discrepancies or any uncorrected issues
    significant_discrepancies = @discrepancies.any? do |d|
      d[:difference].abs >= SIGNIFICANT_DISCREPANCY_THRESHOLD
    end

    uncorrected_discrepancies = @discrepancies.count > @corrections_made.count

    significant_discrepancies || uncorrected_discrepancies
  end

  def create_reconciliation_notifications
    if @discrepancies.any?
      # Create summary notification
      total_discrepancies = @discrepancies.count
      corrected_count = @corrections_made.count

      status = if corrected_count == total_discrepancies
        "info"
      elsif corrected_count > 0
        "warning"
      else
        "error"
      end

      message = "Found #{total_discrepancies} inventory discrepancies for '#{@kuralis_product.title}'. " \
                "#{corrected_count} were automatically corrected."

      Notification.create!(
        shop_id: @shop.id,
        title: "Inventory Reconciliation",
        message: message,
        category: "inventory",
        status: status,
        metadata: {
          product_id: @kuralis_product.id,
          discrepancies: @discrepancies,
          corrections: @corrections_made,
          total_discrepancies: total_discrepancies,
          corrected_count: corrected_count
        }
      )
    end
  end

  def shopify_inventory_query
    <<~GQL
      query($id: ID!) {
        product(id: $id) {
          id
          variants(first: 1) {
            edges {
              node {
                id
                inventoryQuantity
              }
            }
          }
        }
      }
    GQL
  end
end
