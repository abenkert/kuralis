class ShopifyEbayAccount < ApplicationRecord
  belongs_to :shop
  has_many :ebay_listings, dependent: :destroy

  # Encrypt sensitive eBay tokens
  encrypts :access_token
  encrypts :refresh_token

  validates :shop, presence: true
  validates :access_token, presence: true

  # Helper methods for shipping profiles
  def shipping_profile_weight(profile_id)
    shipping_profile_weights[profile_id]&.to_d
  end

  def set_shipping_profile_weight(profile_id, weight)
    self.shipping_profile_weights = shipping_profile_weights.merge(profile_id => weight.to_s)
  end

  def shipping_profile_name(profile_id)
    shipping_profiles.find { |profile| profile["id"] == profile_id }&.dig("name")
  end

  # Helper methods for store categories
  def store_category_name(category_id)
    store_categories.find { |category| category["id"] == category_id }&.dig("name")
  end

  def update_store_categories(categories)
    self.store_categories = categories
    save
  end

  def update_shipping_profiles(profiles)
    self.shipping_profiles = profiles
    save
  end

  # Category tag mapping methods
  def category_tag(category_id)
    category_tag_mappings[category_id]
  end

  def set_category_tag(category_id, tag)
    self.category_tag_mappings = category_tag_mappings.merge(category_id => tag)
    save
  end

  def remove_category_tag(category_id)
    self.category_tag_mappings = category_tag_mappings.except(category_id)
    save
  end

  def tags_for_listing(ebay_listing)
    tags = []
    tags << category_tag(ebay_listing.store_category_id) if ebay_listing.store_category_id.present?
    tags.compact
  end
end
