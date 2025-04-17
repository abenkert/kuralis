class CreateShopifyProducts < ActiveRecord::Migration[7.0]
  def change
    create_table :shopify_products do |t|
      # Shopify IDs
      t.string :shopify_product_id, null: false
      t.string :shopify_variant_id, null: false
      
      # Pricing and Inventory
      t.decimal :price, precision: 10, scale: 2
      t.integer :quantity
      t.string :sku
      t.string :inventory_location
      
      # Status and Visibility
      t.string :status, default: 'active'
      t.boolean :published, default: true
      
      # Shopify specific fields
      t.string :title 
      t.string :description
      t.string :handle
      t.string :product_type
      t.string :vendor
      t.jsonb :tags
      t.jsonb :options  # For variant options like size, color, etc.
      
      # Timestamps
      t.datetime :last_synced_at
      t.timestamps
    end

    # Indexes
    add_index :shopify_products, :shopify_product_id, unique: true
    add_index :shopify_products, :shopify_variant_id
    add_index :shopify_products, :status
  end
end