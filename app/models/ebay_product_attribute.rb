# This model stores the configuration and preferences for how a Kuralis Product
# should be listed on eBay. It serves as a template/draft for future eBay listings
# and is NOT a representation of an actual eBay listing (see EbayListing model for that).
#
# Key differences from EbayListing:
# - This stores listing preferences BEFORE a product is listed on eBay
# - Does not have an ebay_item_id as it represents potential/future listings
# - One-to-one relationship with KuralisProduct
# - Source of truth for how a product should be listed on eBay
#
# Example usage:
# - Storing category selection before listing
# - Saving condition and item specifics before listing
# - Maintaining listing preferences for future/repeat listings
class EbayProductAttribute < ApplicationRecord
    belongs_to :kuralis_product, optional: true
    belongs_to :category, class_name: "EbayCategory", primary_key: "category_id", foreign_key: "category_id", optional: true

    # Modified validation to allow new records temporarily
    validates :kuralis_product_id, uniqueness: true, if: -> { kuralis_product_id.present? }

    # Validations will be checked at listing time instead of at product creation time
    # so users can create products without eBay information

    # Always use fixed price format
    def listing_format
      "fixed_price"
    end

    # Helper methods for item specifics
    def item_specific(name)
      return nil unless item_specifics.present?

      # Try both string and symbol keys, and handle different naming conventions
      key = name.to_s
      key_underscore = key.downcase.gsub(/\s+/, "_")

      item_specifics[key] || item_specifics[key_underscore] ||
      item_specifics[key.to_sym] || item_specifics[key_underscore.to_sym]
    end

    def has_item_specific?(name)
      item_specific(name).present?
    end

    def category_item_specifics
      category&.metadata&.dig("item_specifics") || {}
    end

    def find_or_initialize_item_specifics(shop)
      return category_item_specifics if category_item_specifics.present?

       # Cache the results in the category metadata
       category = EbayCategory.find_by(category_id: category_id, marketplace_id: marketplace_id)
       if category.present?
        service = Ebay::TaxonomyService.new(shop.shopify_ebay_account)
        item_specifics = service.fetch_item_aspects(category_id)
        metadata = category.metadata || {}
        metadata["item_specifics"] = item_specifics
        category.update(metadata: metadata)
        item_specifics
       end
    end
end
