class AddCancellationFieldsToOrders < ActiveRecord::Migration[8.0]
  def change
    add_column :orders, :cancelled_at, :datetime
    add_column :orders, :cancellation_reason, :text

    # Add index for querying cancelled orders
    add_index :orders, :cancelled_at
    add_index :orders, [ :platform, :cancelled_at ]
  end
end
