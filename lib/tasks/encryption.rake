namespace :db do
  namespace :encryption do
    desc "Migrate existing tokens to encrypted format"
    task migrate_tokens: :environment do
      puts "🔐 Starting token encryption migration..."

      # Temporarily disable encryption to read backup data
      Shop.class_eval do
        # Remove encryption temporarily
        def self.encrypts(*args); end
      end

      ShopifyEbayAccount.class_eval do
        # Remove encryption temporarily
        def self.encrypts(*args); end
      end

      # Re-enable encryption by reloading the models
      load Rails.root.join("app/models/shop.rb")
      load Rails.root.join("app/models/shopify_ebay_account.rb")

      # Migrate Shop tokens
      shops_updated = 0
      Shop.where.not(shopify_token_backup: nil).find_each do |shop|
        begin
          # Use update_column to bypass validations and callbacks
          shop.update_column(:shopify_token, shop.shopify_token_backup)
          shops_updated += 1
          print "."
        rescue => e
          puts "\\nError updating shop #{shop.id}: #{e.message}"
        end
      end

      puts "\\n✅ Updated #{shops_updated} shop tokens"

      # Migrate eBay account tokens
      accounts_updated = 0
      ShopifyEbayAccount.where("access_token_backup IS NOT NULL OR refresh_token_backup IS NOT NULL").find_each do |account|
        begin
          updates = {}
          updates[:access_token] = account.access_token_backup if account.access_token_backup.present?
          updates[:refresh_token] = account.refresh_token_backup if account.refresh_token_backup.present?

          # Use update_columns to bypass validations and callbacks
          account.update_columns(updates) if updates.any?
          accounts_updated += 1
          print "."
        rescue => e
          puts "\\nError updating eBay account #{account.id}: #{e.message}"
        end
      end

      puts "\\n✅ Updated #{accounts_updated} eBay account tokens"

      # Verify encryption is working
      puts "\\n🔍 Verifying encryption..."

      # Test a shop token
      test_shop = Shop.where.not(shopify_token: nil).first
      if test_shop
        # The token should be encrypted in the database but decrypted when accessed
        raw_token = ActiveRecord::Base.connection.execute(
          "SELECT shopify_token FROM shops WHERE id = #{test_shop.id}"
        ).first["shopify_token"]

        if raw_token != test_shop.shopify_token
          puts "✅ Shop tokens are properly encrypted"
        else
          puts "⚠️  Shop tokens may not be encrypted properly"
        end
      end

      # Test an eBay account token
      test_account = ShopifyEbayAccount.where.not(access_token: nil).first
      if test_account
        raw_token = ActiveRecord::Base.connection.execute(
          "SELECT access_token FROM shopify_ebay_accounts WHERE id = #{test_account.id}"
        ).first["access_token"]

        if raw_token != test_account.access_token
          puts "✅ eBay tokens are properly encrypted"
        else
          puts "⚠️  eBay tokens may not be encrypted properly"
        end
      end

      puts "\\n🎉 Token encryption migration completed!"
      puts "\\n📋 Next steps:"
      puts "   1. Test your application to ensure tokens work correctly"
      puts "   2. If everything works, run: rails db:encryption:cleanup_backups"
      puts "   3. Monitor your application for any token-related issues"
    end

    desc "Clean up backup token columns after successful encryption"
    task cleanup_backups: :environment do
      puts "🧹 Cleaning up backup token columns..."

      print "Are you sure you want to remove backup columns? This cannot be undone. (y/N): "
      response = STDIN.gets.chomp.downcase

      if response == "y" || response == "yes"
        ActiveRecord::Migration.remove_column :shops, :shopify_token_backup if column_exists?(:shops, :shopify_token_backup)
        ActiveRecord::Migration.remove_column :shopify_ebay_accounts, :access_token_backup if column_exists?(:shopify_ebay_accounts, :access_token_backup)
        ActiveRecord::Migration.remove_column :shopify_ebay_accounts, :refresh_token_backup if column_exists?(:shopify_ebay_accounts, :refresh_token_backup)

        puts "✅ Backup columns removed successfully"
      else
        puts "❌ Cleanup cancelled"
      end
    end

    desc "Verify token encryption status"
    task verify: :environment do
      puts "🔍 Verifying token encryption status..."

      # Check if encryption is configured
      if Rails.application.credentials.active_record_encryption.present?
        puts "✅ Active Record encryption is configured"
      else
        puts "❌ Active Record encryption is NOT configured"
        exit 1
      end

      # Check shops
      total_shops = Shop.count
      shops_with_tokens = Shop.where.not(shopify_token: nil).count
      puts "📊 Shops: #{shops_with_tokens}/#{total_shops} have tokens"

      # Check eBay accounts
      total_accounts = ShopifyEbayAccount.count
      accounts_with_tokens = ShopifyEbayAccount.where.not(access_token: nil).count
      puts "📊 eBay Accounts: #{accounts_with_tokens}/#{total_accounts} have tokens"

      # Check if backup columns exist
      backup_columns = []
      backup_columns << "shops.shopify_token_backup" if column_exists?(:shops, :shopify_token_backup)
      backup_columns << "shopify_ebay_accounts.access_token_backup" if column_exists?(:shopify_ebay_accounts, :access_token_backup)
      backup_columns << "shopify_ebay_accounts.refresh_token_backup" if column_exists?(:shopify_ebay_accounts, :refresh_token_backup)

      if backup_columns.any?
        puts "⚠️  Backup columns still exist: #{backup_columns.join(', ')}"
        puts "   Run 'rails db:encryption:cleanup_backups' when ready"
      else
        puts "✅ No backup columns found"
      end

      puts "\\n🔐 Token encryption verification completed!"
    end
  end
end

def column_exists?(table, column)
  ActiveRecord::Base.connection.column_exists?(table, column)
end
