class OrderItem < ApplicationRecord
  belongs_to :order
  belongs_to :kuralis_product, optional: true

  validates :quantity, presence: true, numericality: { greater_than: 0 }
end
