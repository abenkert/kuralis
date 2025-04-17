class AddSellerAndReturnProfiles < ActiveRecord::Migration[8.0]
  def change
    add_column :shopify_ebay_accounts, :payment_profiles, :jsonb, default: []
    add_column :shopify_ebay_accounts, :return_profiles, :jsonb, default: []

    add_index :shopify_ebay_accounts, :payment_profiles, using: :gin
    add_index :shopify_ebay_accounts, :return_profiles, using: :gin
  end
end
