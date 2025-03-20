class EbayProductAttribute < ApplicationRecord
    belongs_to :kuralis_product, optional: true
    belongs_to :category, class_name: "EbayCategory", primary_key: "category_id", foreign_key: "category_id", optional: true

    # Modified validation to allow new records temporarily
    validates :kuralis_product_id, uniqueness: true, if: -> { kuralis_product_id.present? }

    # Add validations for eBay-specific fields

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
