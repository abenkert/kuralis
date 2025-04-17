class CreateOrders < ActiveRecord::Migration[8.0]
  def change
    create_table :orders do |t|
      # Relationships
      t.references :shop, null: false, foreign_key: true
      
      # Platform Information
      t.string :platform, null: false  # 'shopify' or 'ebay'
      t.string :platform_order_id, null: false  # shopify_order_id or ebay_order_id
      t.string :platform_order_number  # human readable order number
      
      # Customer Information
      t.string :customer_name
      t.jsonb :shipping_address
      
      # Order Details
      t.string :status
      t.decimal :subtotal, precision: 10, scale: 2
      t.decimal :shipping_cost, precision: 10, scale: 2
      t.decimal :total_price, precision: 10, scale: 2
      
      # Payment Information
      t.string :payment_status
      t.datetime :paid_at
      
      # Fulfillment
      t.string :fulfillment_status
      t.string :tracking_number
      t.string :tracking_company
      t.datetime :shipped_at
      
      # Platform-specific data
      t.jsonb :platform_data, default: {}  # Store any platform-specific fields
      
      # Timestamps
      t.datetime :order_placed_at  # When the customer placed the order
      t.datetime :last_synced_at   # Last sync with platform
      t.timestamps
    end

    # Indexes
    add_index :orders, [:platform, :platform_order_id], unique: true
    add_index :orders, :platform_order_number
    add_index :orders, :status
    add_index :orders, :payment_status
    add_index :orders, :fulfillment_status
    add_index :orders, :order_placed_at
  end
end 