class InventoryTransaction < ApplicationRecord
  belongs_to :kuralis_product
  belongs_to :order_item, optional: true

  validates :quantity, presence: true
  validates :transaction_type, presence: true, inclusion: { in: %w[allocation release reconciliation] }
  validates :previous_quantity, presence: true
  validates :new_quantity, presence: true

  before_validation :set_quantities

  private

  def set_quantities
    return if previous_quantity.present? && new_quantity.present?
    
    self.previous_quantity = kuralis_product.quantity
    self.new_quantity = previous_quantity + quantity
  end
end 