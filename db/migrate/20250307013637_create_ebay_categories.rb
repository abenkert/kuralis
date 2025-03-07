class CreateEbayCategories < ActiveRecord::Migration[8.0]
  def change
    create_table :ebay_categories do |t|
      t.string :category_id, null: false
      t.string :name, null: false
      t.string :parent_id
      t.integer :level, null: false, default: 1
      t.boolean :leaf, null: false, default: false
      t.string :marketplace_id, null: false, default: 'EBAY_US'
      t.jsonb :metadata, default: {}

      t.timestamps
    end
    
    add_index :ebay_categories, :category_id
    add_index :ebay_categories, :parent_id
    add_index :ebay_categories, [:marketplace_id, :category_id], unique: true
    add_index :ebay_categories, [:marketplace_id, :parent_id]
    add_index :ebay_categories, :name
  end
end
