class CreateKuralisProducts < ActiveRecord::Migration[7.0]
  def change
    create_table :kuralis_products do |t|
      # Core product information
      t.string :title, null: false
      t.text :description
      t.text :description_html
      t.decimal :base_price, precision: 10, scale: 2
      t.integer :base_quantity, default: 0
      t.string :sku
      t.string :brand
      t.string :condition
      t.string :location
      
      # Media and specifications
      t.jsonb :images, default: []  # Array of image URLs/data
      t.jsonb :attributes, default: {}  # Product attributes/specs
      
      # Relationships
      t.references :shop, foreign_key: true, null: false
      t.references :shopify_product, foreign_key: true, null: true
      t.references :ebay_listing, foreign_key: true, null: true
      
      # Source and sync information
      t.string :source_platform  # 'ebay', 'shopify', 'manual'
      t.datetime :last_synced_at
      
      # Status
      t.string :status, default: 'active'
      
      # Timestamps
      t.timestamps
    end

    # Indexes
    add_index :kuralis_products, :sku
    add_index :kuralis_products, :status
    add_index :kuralis_products, :source_platform
  end
end
