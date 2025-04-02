class KuralisShopSetting < ApplicationRecord
  belongs_to :shop

  validates :category, presence: true
  validates :key, presence: true, uniqueness: { scope: [ :shop_id, :category ] }
  validates :value, presence: true

  # Define common categories
  CATEGORIES = {
    general: "general",
    ebay: "ebay",
    shopify: "shopify",
    inventory: "inventory",
    notifications: "notifications"
  }.freeze

  BOOLEAN_SETTINGS = [
    "store_location_in_description",
    "store_location_in_specifics",
    "append_description",
    "archive_products"
  ].freeze

  # Scopes
  scope :by_category, ->(category) { where(category: category) }

  # Class methods for easy access
  class << self
    def get_setting(shop, key)
      setting = find_by(shop: shop, key: key)
      return nil unless setting

      if BOOLEAN_SETTINGS.include?(key)
        setting.boolean_value
      else
        setting.value
      end
    end

    def set_setting(shop, category, key, value)
      setting = find_or_initialize_by(shop: shop, category: category, key: key)
      setting.value = value
      setting.save
    end

    # Batch get settings by category
    def get_category_settings(shop, category)
      where(shop: shop, category: category).each_with_object({}) do |setting, hash|
        hash[setting.key] = BOOLEAN_SETTINGS.include?(setting.key) ? setting.boolean_value : setting.value
      end
    end
  end

  # Instance methods
  def boolean_value
    return false if value.nil?
    ActiveModel::Type::Boolean.new.cast(value)
  end

  def update_value(new_value)
    update(value: new_value)
  end

  def update_metadata(new_metadata)
    update(metadata: new_metadata)
  end
end
