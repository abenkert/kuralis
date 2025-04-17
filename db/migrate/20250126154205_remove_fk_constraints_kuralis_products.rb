class RemoveFkConstraintsKuralisProducts < ActiveRecord::Migration[8.0]
  def change
    # Remove the existing foreign key if it exists
    remove_foreign_key :kuralis_products, :shopify_products if foreign_key_exists?(:kuralis_products, :shopify_products)
    remove_foreign_key :kuralis_products, :ebay_listings if foreign_key_exists?(:kuralis_products, :ebay_listings)
    # Add the foreign key back with ON DELETE NULL option
    add_foreign_key :kuralis_products, :shopify_products, on_delete: :nullify
    add_foreign_key :kuralis_products, :ebay_listings, on_delete: :nullify
  end
end
