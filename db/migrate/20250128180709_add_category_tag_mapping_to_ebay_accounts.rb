class AddCategoryTagMappingToEbayAccounts < ActiveRecord::Migration[8.0]
  def change
    add_column :shopify_ebay_accounts, :category_tag_mappings, :jsonb, default: {}, null: false
    # Example structure: {"123": "vintage-electronics", "456": "rare-books"}
    # Where "123" is the eBay store_category_id and "vintage-electronics" is the Shopify tag
  end
end
