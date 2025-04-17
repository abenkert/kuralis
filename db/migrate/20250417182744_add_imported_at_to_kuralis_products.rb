class AddImportedAtToKuralisProducts < ActiveRecord::Migration[8.0]
  def change
    add_column :kuralis_products, :imported_at, :datetime
    add_index :kuralis_products, :imported_at

    # Initialize with created_at timestamp for existing products
    reversible do |dir|
      dir.up do
        execute <<-SQL
          UPDATE kuralis_products
          SET imported_at = created_at
          WHERE imported_at IS NULL
        SQL
      end
    end
  end
end
