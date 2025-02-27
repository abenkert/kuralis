class Order < ApplicationRecord
  belongs_to :shop
  has_many :order_items, dependent: :destroy
  
  validates :platform, presence: true
  validates :platform_order_id, presence: true, 
            uniqueness: { scope: :platform }
  
  # Scopes
  scope :shopify_orders, -> { where(platform: 'shopify') }
  scope :ebay_orders, -> { where(platform: 'ebay') }
  scope :recent, -> { order(order_placed_at: :desc) }
  
  def total_items
    order_items.sum(:quantity)
  end
  
  def platform_icon
    platform == 'shopify' ? 'bi-shop' : 'bi-bag'
  end

  # TODO: This is a temporary method to check if the order is cancelled.
  # We will need to add a more robust way to check if the order is cancelled.
  def cancelled?
    status == 'cancelled'
  end
end 