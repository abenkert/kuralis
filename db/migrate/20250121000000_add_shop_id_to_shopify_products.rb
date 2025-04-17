class AddShopIdToShopifyProducts < ActiveRecord::Migration[7.0]
  def change
    add_reference :shopify_products, :shop, null: false, foreign_key: true
  end
end 