class AddInitialQuantityToKuralisProducts < ActiveRecord::Migration[8.0]
  def change
    add_column :kuralis_products, :initial_quantity, :integer

    # Initialize with current base_quantity for existing products
    reversible do |dir|
      dir.up do
        execute <<-SQL
          UPDATE kuralis_products
          SET initial_quantity = base_quantity
          WHERE initial_quantity IS NULL
        SQL
      end
    end
  end
end
