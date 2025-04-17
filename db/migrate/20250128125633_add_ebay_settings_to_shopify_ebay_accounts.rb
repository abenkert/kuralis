class AddEbaySettingsToShopifyEbayAccounts < ActiveRecord::Migration[8.0]
  def change
    add_column :shopify_ebay_accounts, :store_categories, :jsonb, default: [], null: false
    # [{"id": "123", "name": "Electronics"}, {"id": "456", "name": "Books"}]
    
    add_column :shopify_ebay_accounts, :shipping_profiles, :jsonb, default: [], null: false
    # [{"id": "123", "name": "Standard Shipping"}, {"id": "456", "name": "Express"}]
    
    add_column :shopify_ebay_accounts, :shipping_profile_weights, :jsonb, default: {}, null: false
    # {"123": "8.0", "456": "16.0"} # weights in ounces
  end
end
