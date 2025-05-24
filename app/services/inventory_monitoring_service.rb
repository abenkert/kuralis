class InventoryMonitoringService
  # Thresholds for alerting
  CRITICAL_LOW_INVENTORY_THRESHOLD = 5
  WARNING_LOW_INVENTORY_THRESHOLD = 10
  FAILED_ALLOCATION_THRESHOLD = 5 # per hour
  DISCREPANCY_PERCENTAGE_THRESHOLD = 10.0

  def self.check_inventory_health(shop_id = nil)
    new(shop_id).perform_health_check
  end

  def self.generate_inventory_report(shop_id, period = 24.hours)
    new(shop_id).generate_report(period)
  end

  def initialize(shop_id = nil)
    @shop_id = shop_id
    @alerts = []
    @metrics = {}
  end

  def perform_health_check
    Rails.logger.info "Starting inventory health check for shop_id=#{@shop_id || 'all'}"

    # Check for products with critically low inventory
    check_low_inventory

    # Check for recent failed allocations
    check_failed_allocations

    # Check for platform discrepancies
    check_platform_discrepancies

    # Check for stale inventory data
    check_stale_inventory_data

    # Check for stuck inventory transactions
    check_stuck_transactions

    # Generate summary
    generate_health_summary
  end

  def generate_report(period)
    start_time = period.ago

    @metrics = {
      period: period,
      start_time: start_time,
      products: calculate_product_metrics(start_time),
      transactions: calculate_transaction_metrics(start_time),
      orders: calculate_order_metrics(start_time),
      alerts: calculate_alert_metrics(start_time)
    }

    @metrics
  end

  private

  def check_low_inventory
    scope = KuralisProduct.active
    scope = scope.where(shop_id: @shop_id) if @shop_id

    # Critical: Products with 0-5 units
    critical_products = scope.where(base_quantity: 0..CRITICAL_LOW_INVENTORY_THRESHOLD)

    # Warning: Products with 6-10 units
    warning_products = scope.where(base_quantity: (CRITICAL_LOW_INVENTORY_THRESHOLD + 1)..WARNING_LOW_INVENTORY_THRESHOLD)

    if critical_products.any?
      @alerts << {
        type: "critical_low_inventory",
        severity: "critical",
        count: critical_products.count,
        products: critical_products.pluck(:id, :title, :base_quantity),
        message: "#{critical_products.count} products have critically low inventory (≤#{CRITICAL_LOW_INVENTORY_THRESHOLD})"
      }
    end

    if warning_products.any?
      @alerts << {
        type: "warning_low_inventory",
        severity: "warning",
        count: warning_products.count,
        products: warning_products.pluck(:id, :title, :base_quantity),
        message: "#{warning_products.count} products have low inventory (≤#{WARNING_LOW_INVENTORY_THRESHOLD})"
      }
    end
  end

  def check_failed_allocations
    one_hour_ago = 1.hour.ago

    scope = InventoryTransaction.where(
      transaction_type: "allocation_failed",
      created_at: one_hour_ago..Time.current
    )
    scope = scope.joins(:kuralis_product).where(kuralis_products: { shop_id: @shop_id }) if @shop_id

    failed_count = scope.count

    if failed_count >= FAILED_ALLOCATION_THRESHOLD
      @alerts << {
        type: "high_allocation_failures",
        severity: "error",
        count: failed_count,
        threshold: FAILED_ALLOCATION_THRESHOLD,
        message: "#{failed_count} allocation failures in the last hour (threshold: #{FAILED_ALLOCATION_THRESHOLD})"
      }
    end
  end

  def check_platform_discrepancies
    scope = KuralisProduct.active
    scope = scope.where(shop_id: @shop_id) if @shop_id

    discrepancies = []

    scope.includes(:shopify_product, :ebay_listing).find_each do |product|
      # Check Shopify discrepancy
      if product.shopify_product.present?
        shopify_qty = product.shopify_product.quantity || 0
        if quantity_discrepancy_significant?(product.base_quantity, shopify_qty)
          discrepancies << {
            product_id: product.id,
            title: product.title,
            platform: "shopify",
            kuralis_qty: product.base_quantity,
            platform_qty: shopify_qty,
            percentage_diff: calculate_percentage_difference(product.base_quantity, shopify_qty)
          }
        end
      end

      # Check eBay discrepancy
      if product.ebay_listing.present?
        ebay_qty = product.ebay_listing.quantity || 0
        if quantity_discrepancy_significant?(product.base_quantity, ebay_qty)
          discrepancies << {
            product_id: product.id,
            title: product.title,
            platform: "ebay",
            kuralis_qty: product.base_quantity,
            platform_qty: ebay_qty,
            percentage_diff: calculate_percentage_difference(product.base_quantity, ebay_qty)
          }
        end
      end
    end

    if discrepancies.any?
      @alerts << {
        type: "platform_discrepancies",
        severity: "warning",
        count: discrepancies.count,
        discrepancies: discrepancies,
        message: "Found #{discrepancies.count} platform inventory discrepancies"
      }
    end
  end

  def check_stale_inventory_data
    stale_threshold = 4.hours.ago

    scope = KuralisProduct.where("last_inventory_update < ? OR last_inventory_update IS NULL", stale_threshold)
    scope = scope.where(shop_id: @shop_id) if @shop_id

    stale_products = scope.count

    if stale_products > 0
      @alerts << {
        type: "stale_inventory_data",
        severity: "info",
        count: stale_products,
        threshold: "4 hours",
        message: "#{stale_products} products have stale inventory data (last updated >4 hours ago)"
      }
    end
  end

  def check_stuck_transactions
    stuck_threshold = 30.minutes.ago

    scope = InventoryTransaction.where(
      processed: false,
      created_at: ..stuck_threshold
    )
    scope = scope.joins(:kuralis_product).where(kuralis_products: { shop_id: @shop_id }) if @shop_id

    stuck_count = scope.count

    if stuck_count > 0
      @alerts << {
        type: "stuck_transactions",
        severity: "error",
        count: stuck_count,
        threshold: "30 minutes",
        message: "#{stuck_count} inventory transactions are stuck in unprocessed state"
      }
    end
  end

  def quantity_discrepancy_significant?(qty1, qty2)
    return false if qty1 == qty2

    max_qty = [ qty1, qty2 ].max
    return true if max_qty.zero? # Any discrepancy is significant when one is zero

    percentage_diff = ((qty1 - qty2).abs.to_f / max_qty) * 100
    percentage_diff >= DISCREPANCY_PERCENTAGE_THRESHOLD
  end

  def calculate_percentage_difference(qty1, qty2)
    return 0.0 if qty1 == qty2

    max_qty = [ qty1, qty2 ].max
    return 100.0 if max_qty.zero?

    ((qty1 - qty2).abs.to_f / max_qty) * 100
  end

  def generate_health_summary
    severity_counts = @alerts.group_by { |alert| alert[:severity] }
                            .transform_values(&:count)

    summary = {
      timestamp: Time.current,
      shop_id: @shop_id,
      overall_status: determine_overall_status(severity_counts),
      total_alerts: @alerts.count,
      alerts_by_severity: severity_counts,
      alerts: @alerts
    }

    # Create notification if there are critical issues
    if severity_counts["critical"]&.positive?
      create_critical_alert_notification(summary)
    end

    summary
  end

  def determine_overall_status(severity_counts)
    return "critical" if severity_counts["critical"]&.positive?
    return "warning" if severity_counts["error"]&.positive? || severity_counts["warning"]&.positive?
    return "info" if severity_counts["info"]&.positive?
    "healthy"
  end

  def create_critical_alert_notification(summary)
    critical_alerts = @alerts.select { |alert| alert[:severity] == "critical" }

    message = "Critical inventory issues detected:\n"
    critical_alerts.each do |alert|
      message += "• #{alert[:message]}\n"
    end

    # Create notification for the shop or all shop owners if shop_id is nil
    if @shop_id
      shop = Shop.find(@shop_id)
      Notification.create!(
        shop_id: shop.id,
        title: "Critical Inventory Alert",
        message: message.strip,
        category: "inventory",
        status: "error",
        metadata: {
          health_summary: summary,
          critical_alerts: critical_alerts
        }
      )
    else
      # System-wide alert - you might want to notify administrators
      Rails.logger.error "CRITICAL INVENTORY ALERT: #{message}"
    end
  end

  def calculate_product_metrics(start_time)
    scope = KuralisProduct
    scope = scope.where(shop_id: @shop_id) if @shop_id

    {
      total_products: scope.count,
      active_products: scope.where(status: "active").count,
      inactive_products: scope.where(status: "inactive").count,
      completed_products: scope.where(status: "completed").count,
      out_of_stock: scope.where(base_quantity: 0).count,
      low_stock: scope.where(base_quantity: 1..CRITICAL_LOW_INVENTORY_THRESHOLD).count,
      total_inventory_value: calculate_total_inventory_value(scope)
    }
  end

  def calculate_transaction_metrics(start_time)
    scope = InventoryTransaction.where(created_at: start_time..Time.current)
    scope = scope.joins(:kuralis_product).where(kuralis_products: { shop_id: @shop_id }) if @shop_id

    {
      total_transactions: scope.count,
      allocations: scope.where(transaction_type: "allocation").count,
      releases: scope.where(transaction_type: "release").count,
      failed_allocations: scope.where(transaction_type: "allocation_failed").count,
      manual_adjustments: scope.where(transaction_type: "manual_adjustment").count,
      reconciliations: scope.where(transaction_type: "reconciliation").count,
      unprocessed: scope.where(processed: false).count
    }
  end

  def calculate_order_metrics(start_time)
    scope = Order.where(order_placed_at: start_time..Time.current)
    scope = scope.where(shop_id: @shop_id) if @shop_id

    {
      total_orders: scope.count,
      ebay_orders: scope.where(platform: "ebay").count,
      shopify_orders: scope.where(platform: "shopify").count,
      fulfilled_orders: scope.where(fulfillment_status: [ "FULFILLED", "fulfilled" ]).count,
      cancelled_orders: scope.where(fulfillment_status: [ "CANCELLED", "cancelled" ]).count
    }
  end

  def calculate_alert_metrics(start_time)
    # This would track historical alerts if you store them
    # For now, return current alert summary
    {
      current_alerts: @alerts.count,
      critical_alerts: @alerts.count { |a| a[:severity] == "critical" },
      warning_alerts: @alerts.count { |a| a[:severity] == "warning" },
      info_alerts: @alerts.count { |a| a[:severity] == "info" }
    }
  end

  def calculate_total_inventory_value(scope)
    scope.sum("base_quantity * base_price")
  rescue
    0.0 # Fallback if calculation fails
  end
end
