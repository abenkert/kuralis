class UpdateEbayListingsRelationship < ActiveRecord::Migration[8.0]
  def change
    # Remove the old foreign key if it exists
    remove_reference :ebay_listings, :shop, foreign_key: true, if_exists: true
    
    # Add the new foreign key
    add_reference :ebay_listings, :shopify_ebay_account, foreign_key: true, null: false
  end
end 