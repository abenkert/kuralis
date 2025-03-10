# frozen_string_literal: true

class Shop < ApplicationRecord
  include ShopifyApp::ShopSessionStorageWithScopes

  has_one :shopify_ebay_account, dependent: :destroy
  has_many :kuralis_products, dependent: :destroy
  has_many :orders, dependent: :destroy
  # has_one :user, dependent: :destroy  # Commented out for now
  has_many :shopify_products, dependent: :destroy
  has_many :ai_product_analyses, dependent: :destroy
  
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
    orders.where('created_at > ?', 24.hours.ago).count
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
end
