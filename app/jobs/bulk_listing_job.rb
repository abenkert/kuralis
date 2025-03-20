class BulkListingJob < ApplicationJob
  queue_as :default

  def perform(shop_id:, product_ids:, platforms:)
    shop = Shop.find(shop_id)
    products = shop.kuralis_products.where(id: product_ids)

    # Track results per platform
    results = Hash.new { |h, k| h[k] = { successful_ids: [], failed_ids: [], failed_details: [] } }

    # Process each product
    products.find_each do |product|
      # Process each requested platform
      Array(platforms).each do |platform|
        begin
          case platform
          when "shopify"
            next if product.shopify_product.present?
            Shopify::CreateListingJob.perform_now(product.id)
            results[platform][:successful_ids] << product.id
          when "ebay"
            next if product.ebay_listing.present?
            Ebay::CreateListingJob.perform_now(
              shop_id: shop.id,
              kuralis_product_id: product.id
            )
            results[platform][:successful_ids] << product.id
          end
        rescue => e
          results[platform][:failed_ids] << product.id
          results[platform][:failed_details] << {
            id: product.id,
            title: product.title,
            error: e.message
          }
          Rails.logger.error("Failed to create #{platform} listing for product #{product.id}: #{e.message}")
        end
      end
    end

    # Send notification about completion for each platform
    results.each do |platform, platform_results|
      NotificationService.create(
        shop: shop,
        title: "#{platform.titleize} Bulk Listing Complete",
        message: generate_completion_message(
          platform: platform,
          success_count: platform_results[:successful_ids].size,
          failed_details: platform_results[:failed_details]
        ),
        category: "bulk_listing",
        metadata: {
          platform: platform,
          total_processed: product_ids.size,
          error_details: platform_results[:failed_details]
        },
        failed_product_ids: platform_results[:failed_ids],
        successful_product_ids: platform_results[:successful_ids]
      )
    end
  end

  private

  def generate_completion_message(platform:, success_count:, failed_details:)
    message = "Bulk listing to #{platform.titleize} completed:\n"
    message += "✓ Successfully listed: #{success_count}\n"

    if failed_details.any?
      message += "✗ Failed to list: #{failed_details.size}\n\n"
      message += "Failed products:\n"
      failed_details.each do |product|
        message += "- #{product[:title]} (ID: #{product[:id]}): #{product[:error]}\n"
      end
    end

    message
  end
end
