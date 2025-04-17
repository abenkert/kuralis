class AddWarehouseToProducts < ActiveRecord::Migration[8.0]
  def change
    add_reference :kuralis_products, :warehouse, foreign_key: true

    # Add an after_save callback to set default warehouse if none specified
    reversible do |dir|
      dir.up do
        execute <<-SQL
          UPDATE kuralis_products
          SET warehouse_id = (
            SELECT id FROM warehouses
            WHERE shop_id = kuralis_products.shop_id
            AND is_default = true
            LIMIT 1
          )
          WHERE warehouse_id IS NULL;
        SQL
      end
    end
  end
end
