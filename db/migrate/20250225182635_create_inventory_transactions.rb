class CreateInventoryTransactions < ActiveRecord::Migration[8.0]
  def change
    create_table :inventory_transactions do |t|
      # Relationships
      t.references :kuralis_product, null: false, foreign_key: true
      t.references :order_item, foreign_key: true

      # Transaction Details
      t.integer :quantity, null: false
      t.string :transaction_type, null: false
      t.integer :previous_quantity, null: false
      t.integer :new_quantity, null: false
      t.text :notes

      t.timestamps
    end

    # Indexes
    add_index :inventory_transactions, :transaction_type
    add_index :inventory_transactions, :created_at
  end
end
