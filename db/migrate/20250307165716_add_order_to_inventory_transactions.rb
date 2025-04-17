class AddOrderToInventoryTransactions < ActiveRecord::Migration[8.0]
  def change
    add_reference :inventory_transactions, :order, null: true, foreign_key: true, index: true
  end
end
