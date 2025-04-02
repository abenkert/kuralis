# frozen_string_literal: true

class Shop < ApplicationRecord
  include ShopifyApp::ShopSessionStorageWithScopes

  has_one :shopify_ebay_account, dependent: :destroy
  has_many :kuralis_products, dependent: :destroy
  has_many :orders, dependent: :destroy
  # has_one :user, dependent: :destroy  # Commented out for now
  has_many :shopify_products, dependent: :destroy
  has_many :ai_product_analyses, dependent: :destroy

  has_many :warehouses
  has_one :default_warehouse, -> { where(is_default: true) }, class_name: "Warehouse"

  # Settings methods
  has_many :kuralis_shop_settings, dependent: :destroy

  after_create :create_default_warehouse

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
    get_setting("shopify", "archive_products") || true
  end

  private

  def create_default_warehouse
    # Create a default warehouse with the shop's address information if available
    address = self.address1.presence || "Default Location"
    city = self.city.presence || "New York"
    state = self.province.presence || "NY"
    zip = self.zip.presence || "11004"
    country_code = self.country_code.presence || "US"

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
