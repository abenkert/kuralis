class CreateOrderItems < ActiveRecord::Migration[8.0]
  def change
    create_table :order_items do |t|
      # Relationships
      t.references :order, null: false, foreign_key: true
      t.references :kuralis_product, foreign_key: true, null: true
      
      # Item Details
      t.string :title
      t.string :sku
      t.string :location
      t.integer :quantity
      
      # Platform specific data
      t.jsonb :platform_data, default: {}
      
      t.timestamps
    end

    add_index :order_items, :sku
  end
end 