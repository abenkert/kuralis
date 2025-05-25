# frozen_string_literal: true

class Shop < ApplicationRecord
  include ShopifyApp::ShopSessionStorageWithScopes

  has_one :shopify_ebay_account, dependent: :destroy
  has_many :kuralis_products, dependent: :destroy
  has_many :orders, dependent: :destroy
  # has_one :user, dependent: :destroy  # Commented out for now
  has_many :shopify_products, dependent: :destroy
  has_many :ai_product_analyses, dependent: :destroy
  has_many :job_runs, dependent: :destroy

  has_many :warehouses
  has_one :default_warehouse, -> { where(is_default: true) }, class_name: "Warehouse"

  # Settings methods
  has_many :kuralis_shop_settings, dependent: :destroy

  after_save :create_default_warehouse

  def api_version
    ShopifyApp.configuration.api_version
  end

  def notification_endpoint_url
    if Rails.env.production?
      "https://#{ENV['APP_HOST']}/ebay/notifications"
    else
      "https://#{ENV['DEV_APP_HOST']}/ebay/notifications"
    end
  end

  def shopify_session
    ShopifyAPI::Auth::Session.new(
      shop: shopify_domain,
      access_token: shopify_token
    )
  end

  def recent_orders_count
    orders.where("created_at > ?", 24.hours.ago).count
  end

  def unlinked_products_count
    kuralis_products.unlinked.count
  end

  def ebay_listings_count
    shopify_ebay_account&.ebay_listings&.count || 0
  end

  def recent_orders
    orders.order(created_at: :desc).limit(5)
  end

  def product_distribution_data
    {
      shopify: shopify_products.count,
      ebay: ebay_listings_count,
      unlinked: unlinked_products_count
    }
  end

  def inventory_summary
    products = kuralis_products.active
    {
      total_value: products.sum("base_price * base_quantity"),
      avg_price: products.average(:base_price)&.round(2) || 0,
      total_quantity: products.sum(:base_quantity),
      low_stock_threshold: 5
    }
  end

  def platform_sync_status
    total_products = kuralis_products.active.count
    return { shopify: 0, ebay: 0 } if total_products.zero?

    {
      shopify: ((shopify_products.count.to_f / total_products) * 100).round,
      ebay: ((ebay_listings_count.to_f / total_products) * 100).round
    }
  end

  def get_setting(category, key)
    KuralisShopSetting.get_setting(self, category, key)
  end

  def set_setting(category, key, value)
    KuralisShopSetting.set_setting(self, category, key, value)
  end

  def get_category_settings(category)
    KuralisShopSetting.get_category_settings(self, category)
  end

  # Setting-specific methods
  def store_location_in_description?
    get_setting("general", "store_location_in_description")
  end

  def store_location_in_specifics?
    get_setting("general", "store_location_in_specifics")
  end

  def append_description?
    get_setting("general", "append_description")
  end

  def default_description
    get_setting("general", "default_description") || ""
  end

  def shopify_archive_products?
    setting = get_setting("shopify", "archive_products")
    setting.nil? ? true : setting
  end

  def inventory_sync?
    setting = get_setting("general", "inventory_sync")
    setting.nil? ? false : setting  # Default to false if not set
  end

  private

  def create_default_warehouse
    return if warehouses.any?
    # Create a default warehouse with the shop's address information if available
    address = "Default Location"
    city = "New York"
    state = "NY"
    zip = "11004"
    country_code = "US"

    warehouses.create!(
      name: "Default Warehouse",
      address1: address,
      city: city,
      state: state,
      postal_code: zip,
      country_code: country_code,
      is_default: true,
      active: true
    )
  end
end
