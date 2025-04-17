class AddWeightAndTagsToKuralisProducts < ActiveRecord::Migration[8.0]
  def change
    add_column :kuralis_products, :weight_oz, :decimal, precision: 8, scale: 2
    add_column :kuralis_products, :tags, :jsonb, default: [], null: false
    
    add_index :kuralis_products, :tags, using: :gin
  end
end
