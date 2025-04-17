class RenameAttributesColumnInKuralisProducts < ActiveRecord::Migration[7.0]
  def change
    if column_exists?(:kuralis_products, :attributes)
      rename_column :kuralis_products, :attributes, :product_attributes
    end
  end
end 