class Warehouse < ApplicationRecord
  belongs_to :shop

  validates :name, presence: true
  validates :postal_code, presence: true
  validates :country_code, presence: true
  validates :is_default, uniqueness: { scope: :shop_id }, if: :is_default?

  before_save :ensure_single_default_warehouse
  after_create :set_as_default_if_first

  private

  def ensure_single_default_warehouse
    if is_default? && is_default_changed?
      Warehouse.where(shop_id: shop_id)
              .where.not(id: id)
              .update_all(is_default: false)
    end
  end

  def set_as_default_if_first
    update(is_default: true) if shop.warehouses.count == 1
  end
end
