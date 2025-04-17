class CreateShopifyEbayAccounts < ActiveRecord::Migration[8.0]
  def change
    create_table :shopify_ebay_accounts do |t|
      t.references :shop, null: false, foreign_key: true
      t.string :ebay_user_id
      t.string :access_token
      t.string :refresh_token
      t.datetime :token_expires_at
      t.timestamps
    end
  end
end
