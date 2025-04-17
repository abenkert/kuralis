class RepositionShopifyEbayAccountId < ActiveRecord::Migration[8.0]
  def up
    execute <<-SQL
      ALTER TABLE ebay_listings 
      ALTER COLUMN shopify_ebay_account_id 
      TYPE bigint;
    SQL
  end

  def down
    # No need for down migration as we're just moving the column position
  end
end 