class AddProcessedToInventoryTransactions < ActiveRecord::Migration[8.0]
  def change
    add_column :inventory_transactions, :processed, :boolean, default: false
    add_index :inventory_transactions, :processed
  end
end
