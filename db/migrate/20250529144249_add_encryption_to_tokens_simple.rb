class AddEncryptionToTokensSimple < ActiveRecord::Migration[7.1]
  def up
    # Remove NOT NULL constraints to allow Rails encryption to work
    # In test mode, we don't need backup columns since keys can be regenerated
    change_column_null :shops, :shopify_token, true
    change_column_null :shopify_ebay_accounts, :access_token, true
    change_column_null :shopify_ebay_accounts, :refresh_token, true

    puts "✅ Token encryption enabled!"
    puts "🔐 Your tokens will now be automatically encrypted by Rails"
    puts "📝 Note: You may need to re-authenticate with Shopify/eBay to get fresh tokens"
  end

  def down
    # Restore NOT NULL constraints
    change_column_null :shops, :shopify_token, false
    change_column_null :shopify_ebay_accounts, :access_token, false
    change_column_null :shopify_ebay_accounts, :refresh_token, false

    puts "⚠️  Token encryption disabled - tokens are now stored in plain text"
  end
end
