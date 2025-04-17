class AddPlatformItemIdToOrderItems < ActiveRecord::Migration[8.0]
  def change
    add_column :order_items, :platform, :string, null: false  # 'shopify' or 'ebay'
    add_column :order_items, :platform_item_id, :string
    add_index :order_items, :platform_item_id
  end
end 