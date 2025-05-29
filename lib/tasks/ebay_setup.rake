namespace :ebay do
  desc "Import eBay categories for all shops"
  task import_categories: :environment do
    puts "🏷️  Starting eBay category import for all shops..."

    shops_with_ebay = Shop.joins(:shopify_ebay_account)

    if shops_with_ebay.empty?
      puts "❌ No shops with eBay accounts found. Please connect eBay accounts first."
      exit 1
    end

    puts "📊 Found #{shops_with_ebay.count} shop(s) with eBay accounts"

    shops_with_ebay.find_each do |shop|
      puts "🔄 Importing categories for shop: #{shop.shopify_domain}"

      # Import for default marketplace (EBAY_US)
      ImportEbayCategoriesJob.perform_now(shop.id, "EBAY_US")

      print "."
      sleep(1) # Be nice to eBay API
    end

    puts "\n✅ eBay category import completed for all shops!"
  end

  desc "Import eBay categories for a specific shop"
  task :import_categories_for_shop, [ :shop_domain ] => :environment do |t, args|
    shop_domain = args[:shop_domain]

    if shop_domain.blank?
      puts "❌ Please provide a shop domain:"
      puts "   rails ebay:import_categories_for_shop[shop-name.myshopify.com]"
      exit 1
    end

    shop = Shop.find_by(shopify_domain: shop_domain)

    if shop.nil?
      puts "❌ Shop not found: #{shop_domain}"
      exit 1
    end

    if shop.shopify_ebay_account.nil?
      puts "❌ Shop #{shop_domain} doesn't have an eBay account connected"
      exit 1
    end

    puts "🔄 Importing eBay categories for #{shop_domain}..."
    ImportEbayCategoriesJob.perform_now(shop.id, "EBAY_US")
    puts "✅ eBay category import completed for #{shop_domain}!"
  end

  desc "Import eBay categories for specific marketplace"
  task :import_categories_marketplace, [ :marketplace_id ] => :environment do |t, args|
    marketplace_id = args[:marketplace_id] || "EBAY_US"

    puts "🌍 Starting eBay category import for marketplace: #{marketplace_id}"

    shops_with_ebay = Shop.joins(:shopify_ebay_account)

    if shops_with_ebay.empty?
      puts "❌ No shops with eBay accounts found"
      exit 1
    end

    shops_with_ebay.find_each do |shop|
      puts "🔄 Importing #{marketplace_id} categories for: #{shop.shopify_domain}"
      ImportEbayCategoriesJob.perform_now(shop.id, marketplace_id)
      print "."
      sleep(1)
    end

    puts "\n✅ #{marketplace_id} category import completed!"
  end

  desc "Setup eBay integration (run after fresh deployment)"
  task setup: :environment do
    puts "🚀 Setting up eBay integration for production environment..."
    puts

    # Check if we have any shops
    total_shops = Shop.count
    shops_with_ebay = Shop.joins(:shopify_ebay_account).count

    puts "📊 Environment Status:"
    puts "   Total shops: #{total_shops}"
    puts "   Shops with eBay accounts: #{shops_with_ebay}"
    puts

    if shops_with_ebay == 0
      puts "⚠️  No eBay accounts found. Setup steps:"
      puts "   1. Connect your Shopify shops"
      puts "   2. Connect eBay accounts for each shop"
      puts "   3. Run this task again: rails ebay:setup"
      puts
      puts "❌ Cannot proceed without eBay accounts"
      exit 1
    end

    # Import categories
    puts "🏷️  Step 1: Importing eBay categories..."
    Rake::Task["ebay:import_categories"].invoke
    puts

    # Check category count
    category_count = EbayCategory.count
    puts "📈 Total eBay categories in database: #{category_count}"
    puts

    if category_count > 0
      puts "✅ eBay integration setup completed successfully!"
      puts
      puts "🎯 Next steps:"
      puts "   • Test product listings"
      puts "   • Verify category mappings"
      puts "   • Monitor for any errors"
    else
      puts "⚠️  No categories were imported. Please check:"
      puts "   • eBay API credentials"
      puts "   • Network connectivity"
      puts "   • Application logs"
    end
  end

  desc "Check eBay integration status"
  task status: :environment do
    puts "📊 eBay Integration Status Report"
    puts "=" * 40

    # Shops
    total_shops = Shop.count
    shops_with_ebay = Shop.joins(:shopify_ebay_account).count
    puts "Shops:"
    puts "  Total: #{total_shops}"
    puts "  With eBay accounts: #{shops_with_ebay}"
    puts "  Without eBay: #{total_shops - shops_with_ebay}"
    puts

    # Categories
    category_count = EbayCategory.count
    puts "eBay Categories: #{category_count}"
    puts

    # Recent activity
    recent_jobs = JobRun.where("job_name LIKE '%ImportEbayCategories%'").order(created_at: :desc).limit(5)
    puts "Recent Category Import Jobs:"
    if recent_jobs.any?
      recent_jobs.each do |job|
        status = job.status || "unknown"
        puts "  #{job.created_at.strftime('%Y-%m-%d %H:%M')} - #{status}"
      end
    else
      puts "  No recent import jobs found"
    end
    puts

    # Health check
    if shops_with_ebay > 0 && category_count > 1000
      puts "✅ eBay integration is healthy!"
    elsif shops_with_ebay == 0
      puts "❌ No eBay accounts connected"
    elsif category_count < 1000
      puts "⚠️  Low category count - may need to import categories"
    end
  end
end

# Helper to show available tasks
namespace :ebay do
  desc "Show all available eBay tasks"
  task :help do
    puts "🛠️  Available eBay Setup Tasks:"
    puts
    puts "Production Setup:"
    puts "  rails ebay:setup                    # Complete eBay setup for fresh deployment"
    puts
    puts "Category Management:"
    puts "  rails ebay:import_categories         # Import categories for all shops"
    puts "  rails \"ebay:import_categories_for_shop[domain]\"  # Import for specific shop"
    puts "  rails \"ebay:import_categories_marketplace[EBAY_US]\"  # Import for marketplace"
    puts
    puts "Monitoring:"
    puts "  rails ebay:status                    # Check eBay integration status"
    puts
    puts "Examples (zsh-friendly with quotes):"
    puts "  rails \"ebay:import_categories_for_shop[myshop.myshopify.com]\""
    puts "  rails \"ebay:import_categories_marketplace[EBAY_UK]\""
    puts "  rails \"ebay:import_categories_marketplace[EBAY_CA]\""
    puts
    puts "💡 Tip: Use quotes around commands with [brackets] for zsh compatibility"
  end
end
