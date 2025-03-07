class EbayProductAttribute < ApplicationRecord
    belongs_to :kuralis_product
    
    validates :kuralis_product_id, presence: true, uniqueness: true
    
    # Add validations for eBay-specific fields
  end