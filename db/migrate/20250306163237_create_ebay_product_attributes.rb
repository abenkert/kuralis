# Migration to create ebay_product_attributes table
class CreateEbayProductAttributes < ActiveRecord::Migration[8.0]
  def change
    create_table :ebay_product_attributes do |t|
      t.references :kuralis_product, null: false, foreign_key: true, index: { unique: true }
      
      # eBay-specific fields not already in kuralis_products
      t.string :condition_id
      t.string :condition_description
      t.string :category_id
      t.jsonb :item_specifics, default: {}
      t.string :listing_duration
      t.boolean :best_offer_enabled, default: true
      t.string :shipping_profile_id
      t.string :store_category_id
      
      t.timestamps
    end
  end
end