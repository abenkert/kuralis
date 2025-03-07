class EbayProductAttribute < ApplicationRecord
    belongs_to :kuralis_product
    
    validates :kuralis_product_id, presence: true, uniqueness: true
    
    # Add validations for eBay-specific fields
    
    # Always use fixed price format
    def listing_format
      'fixed_price'
    end
  end