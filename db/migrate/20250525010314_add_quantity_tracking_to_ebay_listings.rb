class AddQuantityTrackingToEbayListings < ActiveRecord::Migration[8.0]
  def change
    add_column :ebay_listings, :total_quantity, :integer, default: 0, null: false
    add_column :ebay_listings, :quantity_sold, :integer, default: 0, null: false

    # Add indexes for performance
    add_index :ebay_listings, :total_quantity
    add_index :ebay_listings, :quantity_sold

    # Add a check constraint to ensure quantity_sold doesn't exceed total_quantity
    add_check_constraint :ebay_listings, "quantity_sold <= total_quantity", name: "quantity_sold_not_greater_than_total"
  end
end
