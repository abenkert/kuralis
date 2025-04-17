class AddLastInventoryUpdateToKuralisProducts < ActiveRecord::Migration[8.0]
  def change
    add_column :kuralis_products, :last_inventory_update, :datetime
    add_index :kuralis_products, :last_inventory_update

    # Initialize with current timestamp for existing products
    reversible do |dir|
      dir.up do
        execute <<-SQL
          UPDATE kuralis_products
          SET last_inventory_update = updated_at
          WHERE last_inventory_update IS NULL
        SQL
      end
    end
  end
end
