class AddLastListingImportAtToShopifyEbayAccounts < ActiveRecord::Migration[8.0]
  def change
    add_column :shopify_ebay_accounts, :last_listing_import_at, :datetime
  end
end 