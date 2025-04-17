class UpdateEbayListingsStructure < ActiveRecord::Migration[8.0]
  def change
    change_table :ebay_listings do |t|
      # Rename existing price column
      t.rename :price, :sale_price
      
      # Add new price and shipping fields
      t.decimal :original_price, precision: 10, scale: 2
      t.string :shipping_profile_id
      t.string :location
      
      # Media
      t.jsonb :image_urls, default: []
      
      # Additional eBay specific fields
      t.string :listing_format  # auction, fixed_price, etc.
      t.string :condition_id
      t.string :condition_description
      t.string :category_id
      t.jsonb :item_specifics, default: {}  # Store eBay item specifics
      t.string :listing_duration
      t.datetime :end_time
      t.boolean :best_offer_enabled, default: false
      
      # Status tracking
      t.string :ebay_status  # active, ended, suspended, etc.
      t.datetime :last_sync_at
    end
  end
end 