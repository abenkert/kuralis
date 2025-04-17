class CreateEbayListings < ActiveRecord::Migration[8.0]
  def change
    create_table :ebay_listings do |t|
      t.references :shop, null: false, foreign_key: true
      t.string :ebay_item_id, null: false
      t.string :title
      t.text :description
      t.decimal :price, precision: 10, scale: 2
      t.integer :quantity
      t.timestamps
    end

    add_index :ebay_listings, [:shop_id, :ebay_item_id], unique: true
  end
end 