class AddImageFieldsToShopifyProducts < ActiveRecord::Migration[7.0]
  def change
    add_column :shopify_products, :image_urls, :string, array: true, default: []
    add_column :shopify_products, :images_last_synced_at, :datetime
  end
end