namespace :images do
  desc "Check how many products are missing images"
  task :check_missing, [ :shop_domain ] => :environment do |t, args|
    if args[:shop_domain].present?
      shop = Shop.find_by(shopify_domain: args[:shop_domain])
      if shop
        count = FixMissingImagesJob.missing_images_count(shop)
        puts "Shop #{shop.shopify_domain}: #{count} products missing images"
      else
        puts "Shop not found: #{args[:shop_domain]}"
      end
    else
      # Check all shops
      Shop.find_each do |shop|
        count = FixMissingImagesJob.missing_images_count(shop)
        puts "Shop #{shop.shopify_domain}: #{count} products missing images" if count > 0
      end
    end
  end

  desc "Fix missing images for products"
  task :fix_missing, [ :shop_domain, :limit ] => :environment do |t, args|
    limit = args[:limit].present? ? args[:limit].to_i : 100

    if args[:shop_domain].present?
      shop = Shop.find_by(shopify_domain: args[:shop_domain])
      if shop
        puts "Starting image fix for #{shop.shopify_domain} (limit: #{limit})"
        result = FixMissingImagesJob.perform_now(shop.id, limit: limit)

        puts "\n=== FIX RESULTS ==="
        puts "Total processed: #{result[:total]}"
        puts "Successfully fixed: #{result[:success]}"
        puts "Failed: #{result[:failed]}"
        puts "No source available: #{result[:no_source]}"
      else
        puts "Shop not found: #{args[:shop_domain]}"
      end
    else
      puts "Please specify a shop domain:"
      puts "  rails images:fix_missing[shop-name.myshopify.com]"
      puts "  rails images:fix_missing[shop-name.myshopify.com,50]  # Limit to 50 products"
    end
  end

  desc "Schedule image fix job (async)"
  task :schedule_fix, [ :shop_domain, :limit ] => :environment do |t, args|
    limit = args[:limit].present? ? args[:limit].to_i : 100

    if args[:shop_domain].present?
      shop = Shop.find_by(shopify_domain: args[:shop_domain])
      if shop
        puts "Scheduling image fix job for #{shop.shopify_domain} (limit: #{limit})"
        FixMissingImagesJob.perform_later(shop.id, limit: limit)
        puts "Job scheduled successfully!"
      else
        puts "Shop not found: #{args[:shop_domain]}"
      end
    else
      puts "Please specify a shop domain:"
      puts "  rails images:schedule_fix[shop-name.myshopify.com]"
    end
  end

  desc "Show detailed stats about product images"
  task :stats, [ :shop_domain ] => :environment do |t, args|
    if args[:shop_domain].present?
      shop = Shop.find_by(shopify_domain: args[:shop_domain])
      unless shop
        puts "Shop not found: #{args[:shop_domain]}"
        exit 1
      end
      shops = [ shop ]
    else
      shops = Shop.all
    end

    shops.each do |shop|
      puts "\n=== #{shop.shopify_domain} ==="

      total_products = shop.kuralis_products.count
      puts "Total products: #{total_products}"

      # Products with images
      with_images = shop.kuralis_products
                        .joins(:images_attachments)
                        .distinct
                        .count
      puts "Products with images: #{with_images}"

      # Products without images
      without_images = shop.kuralis_products
                           .left_joins(:images_attachments)
                           .where(active_storage_attachments: { id: nil })
                           .count
      puts "Products without images: #{without_images}"

      # eBay products without images
      ebay_without_images = shop.kuralis_products
                                .left_joins(:images_attachments)
                                .where(active_storage_attachments: { id: nil })
                                .where(source_platform: "ebay")
                                .count
      puts "eBay products without images: #{ebay_without_images}"

      # Products with image_urls but no attached images
      has_urls_no_images = shop.kuralis_products
                               .left_joins(:images_attachments)
                               .where(active_storage_attachments: { id: nil })
                               .where.not(image_urls: [])
                               .count
      puts "Products with URLs but no attached images: #{has_urls_no_images}"

      percentage_complete = total_products > 0 ? (with_images.to_f / total_products * 100).round(2) : 0
      puts "Image completion rate: #{percentage_complete}%"
    end
  end

  desc "Sample products missing images for debugging"
  task :sample_missing, [ :shop_domain, :count ] => :environment do |t, args|
    count = args[:count].present? ? args[:count].to_i : 5

    if args[:shop_domain].present?
      shop = Shop.find_by(shopify_domain: args[:shop_domain])
      unless shop
        puts "Shop not found: #{args[:shop_domain]}"
        exit 1
      end
    else
      puts "Please specify a shop domain:"
      puts "  rails images:sample_missing[shop-name.myshopify.com]"
      exit 1
    end

    products = shop.kuralis_products
                   .left_joins(:images_attachments)
                   .where(active_storage_attachments: { id: nil })
                   .where(source_platform: "ebay")
                   .includes(:ebay_listing)
                   .limit(count)

    puts "\n=== Sample of #{count} products missing images ==="

    products.each do |product|
      puts "\nProduct ID: #{product.id}"
      puts "Title: #{product.title}"
      puts "eBay Listing ID: #{product.ebay_listing_id}"
      puts "Has image_urls: #{product.image_urls.present? ? product.image_urls.size : 'No'}"

      if product.ebay_listing
        puts "eBay listing has attached images: #{product.ebay_listing.images.attached? ? product.ebay_listing.images.count : 'No'}"
        puts "eBay listing has image_urls: #{product.ebay_listing.image_urls.present? ? product.ebay_listing.image_urls.size : 'No'}"
      else
        puts "No eBay listing found"
      end
      puts "-" * 50
    end
  end
end
