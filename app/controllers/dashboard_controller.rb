class DashboardController < AuthenticatedController
  layout "authenticated"

  def index
    @shop = current_shop
    @inventory_health = calculate_inventory_health
    @recent_activity = gather_recent_activity
    @inventory_trends_data = calculate_inventory_trends
  rescue => e
    Rails.logger.error "Dashboard error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    # Provide fallback data
    @inventory_health = { low_stock_count: 0, out_of_stock_count: 0, price_inconsistencies_count: 0, total_products: 0 }
    @recent_activity = []
    @inventory_trends_data = { labels: [], shopify_data: [], ebay_data: [] }

    flash.now[:alert] = "Some dashboard data could not be loaded. Please try refreshing the page."
  end

  private

  def calculate_inventory_health
    products = @shop.kuralis_products.active

    {
      low_stock_count: products.where("base_quantity > 0 AND base_quantity <= ?", 5).count,
      out_of_stock_count: products.where(base_quantity: 0).count,
      price_inconsistencies_count: calculate_price_inconsistencies,
      total_products: products.count
    }
  end

  def calculate_price_inconsistencies
    inconsistencies = 0

    @shop.kuralis_products.includes(:shopify_product, :ebay_listing).each do |product|
      base_price = product.base_price

      # Check Shopify price inconsistency
      if product.shopify_product&.price && (product.shopify_product.price - base_price).abs > 0.01
        inconsistencies += 1
        next
      end

      # Check eBay price inconsistency
      if product.ebay_listing&.sale_price && (product.ebay_listing.sale_price - base_price).abs > 0.01
        inconsistencies += 1
      end
    end

    inconsistencies
  end

  def gather_recent_activity
    activities = []

    # Recent orders (last 5)
    @shop.recent_orders.each do |order|
      activities << {
        type: "order",
        title: "Order ##{order.platform_order_id}",
        description: "#{order.customer_name || 'Customer'} • #{ActionController::Base.helpers.number_to_currency(order.total_price)} • #{order.platform.titleize}",
        timestamp: order.created_at,
        platform: order.platform,
        icon: order.platform == "shopify" ? "bi-shop" : "bi-tags"
      }
    end

    # Recent product additions (last 3)
    @shop.kuralis_products.order(created_at: :desc).limit(3).each do |product|
      activities << {
        type: "product_added",
        title: "New Product Added",
        description: "#{product.title} • #{ActionController::Base.helpers.time_ago_in_words(product.created_at)} ago",
        timestamp: product.created_at,
        platform: "admin",
        icon: "bi-plus-circle"
      }
    end

    # Recent job completions (last 2)
    @shop.job_runs.completed.order(completed_at: :desc).limit(2).each do |job|
      activities << {
        type: "system_activity",
        title: format_job_title(job.job_class),
        description: "Completed • #{ActionController::Base.helpers.time_ago_in_words(job.completed_at)} ago",
        timestamp: job.completed_at,
        platform: "system",
        icon: "bi-arrow-repeat"
      }
    end

    # Sort by timestamp and take the most recent 8
    activities.sort_by { |a| a[:timestamp] }.reverse.first(8)
  end

  def format_job_title(job_class)
    case job_class
    when /Sync.*Orders/
      "Orders Sync Completed"
    when /Sync.*Products/
      "Products Sync Completed"
    when /Inventory/
      "Inventory Sync Completed"
    else
      "System Task Completed"
    end
  end

  def calculate_inventory_trends
    # Get data for the last 7 days
    dates = (6.days.ago.to_date..Date.current).to_a

    shopify_data = []
    ebay_data = []

    dates.each do |date|
      # For now, we'll calculate current inventory levels
      # In the future, you might want to store daily snapshots
      shopify_inventory = @shop.shopify_products.sum(:quantity) || 0
      ebay_inventory = @shop.shopify_ebay_account&.ebay_listings&.sum(:quantity) || 0

      # Add some variation based on date to show trends
      # This is a placeholder - replace with actual historical data when available
      date_factor = (Date.current - date).to_i
      shopify_data << [ shopify_inventory - (date_factor * 2), 0 ].max
      ebay_data << [ ebay_inventory - (date_factor * 1), 0 ].max
    end

    {
      labels: dates.map { |d| d.strftime("%b %d") },
      shopify_data: shopify_data,
      ebay_data: ebay_data
    }
  end
end
