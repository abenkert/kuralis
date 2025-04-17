class UpdateShopifyEbayAccounts < ActiveRecord::Migration[8.0]
  def change
    remove_column :shopify_ebay_accounts, :ebay_user_id, :string
    rename_column :shopify_ebay_accounts, :token_expires_at, :access_token_expires_at
    add_column :shopify_ebay_accounts, :refresh_token_expires_at, :datetime
  end
end
