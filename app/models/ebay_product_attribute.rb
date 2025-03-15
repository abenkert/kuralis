class EbayProductAttribute < ApplicationRecord
    belongs_to :kuralis_product, optional: true
    
    # Modified validation to allow new records temporarily
    validates :kuralis_product_id, uniqueness: true, if: -> { kuralis_product_id.present? }
    
    # Add validations for eBay-specific fields
    
    # Always use fixed price format
    def listing_format
      'fixed_price'
    end
    
    # Helper methods for item specifics
    def item_specific(name)
      return nil unless item_specifics.present?
      
      # Try both string and symbol keys, and handle different naming conventions
      key = name.to_s
      key_underscore = key.downcase.gsub(/\s+/, '_')
      
      item_specifics[key] || item_specifics[key_underscore] || 
      item_specifics[key.to_sym] || item_specifics[key_underscore.to_sym]
    end
    
    def has_item_specific?(name)
      item_specific(name).present?
    end
  end