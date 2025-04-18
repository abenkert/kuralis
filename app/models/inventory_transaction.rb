class InventoryTransaction < ApplicationRecord
  belongs_to :kuralis_product
  belongs_to :order_item, optional: true
  belongs_to :order, optional: true

  validates :quantity, presence: true
  validates :transaction_type, presence: true, inclusion: { in: %w[allocation release reconciliation allocation_failed manual_adjustment] }
  validates :previous_quantity, presence: true
  validates :new_quantity, presence: true

  before_validation :set_quantities
  before_validation :set_order_from_order_item, if: -> { order_item.present? && order.nil? }

  private

  def set_quantities
    return if previous_quantity.present? && new_quantity.present?

    self.previous_quantity = kuralis_product.quantity
    self.new_quantity = previous_quantity + quantity
  end

  def set_order_from_order_item
    self.order = order_item.order if order_item.order.present?
  end
end
