class Order < ApplicationRecord
  belongs_to :shop
  has_many :order_items, dependent: :destroy
  has_many :inventory_transactions, dependent: :nullify

  validates :platform, presence: true
  validates :platform_order_id, presence: true,
            uniqueness: { scope: :platform }

  # Scopes
  scope :shopify_orders, -> { where(platform: "shopify") }
  scope :ebay_orders, -> { where(platform: "ebay") }
  scope :recent, -> { order(order_placed_at: :desc) }
  scope :cancelled, -> { where.not(cancelled_at: nil) }
  scope :active, -> { where(cancelled_at: nil) }

  def total_items
    order_items.sum(:quantity)
  end

  def platform_icon
    platform == "shopify" ? "bi-shop" : "bi-bag"
  end

  # TODO: This is a temporary method to check if the order is cancelled.
  # We will need to add a more robust way to check if the order is cancelled.
  def cancelled?
    cancelled_at.present? || status == "cancelled"
  end

  def cancelled_before?(timestamp)
    cancelled_at.present? && cancelled_at <= timestamp
  end

  def cancelled_after?(timestamp)
    cancelled_at.present? && cancelled_at > timestamp
  end
end
