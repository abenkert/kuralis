class AddStoreCategoryIdToEbayListing < ActiveRecord::Migration[8.0]
  def change
    add_column :ebay_listings, :store_category_id, :string
    add_index :ebay_listings, :store_category_id
  end
end
