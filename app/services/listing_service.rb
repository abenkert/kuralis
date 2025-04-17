class ListingService
  attr_reader :shop, :product, :platforms, :results

  def initialize(shop:, product:, platforms:)
    @shop = shop
    @product = product
    @platforms = Array(platforms)
    @results = {}
  end

  # Create listings on specified platforms for a single product
  def create_listings
    @platforms.each do |platform|
      begin
        case platform
        when "shopify"
          next if product.shopify_product.present?
          Shopify::CreateListingJob.perform_now(product.id)
          record_success(platform)
        when "ebay"
          next if product.ebay_listing.present?
          Ebay::CreateListingJob.perform_now(
            shop_id: shop.id,
            kuralis_product_id: product.id
          )
          record_success(platform)
        end
      rescue => e
        record_failure(platform, e.message)
        Rails.logger.error("Failed to create #{platform} listing for product #{product.id}: #{e.message}")
      end
    end

    send_notification if results.any?
    results
  end

  private

  def record_success(platform)
    @results[platform] = { success: true, message: "Successfully listed on #{platform.titleize}" }
  end

  def record_failure(platform, error_message)
    @results[platform] = { success: false, message: "Failed to list on #{platform.titleize}: #{error_message}" }
  end

  def send_notification
    summary = "Product Listing Results for: #{product.title}\n\n"

    results.each do |platform, result|
      symbol = result[:success] ? "✓" : "✗"
      summary += "#{symbol} #{platform.titleize}: #{result[:message]}\n"
    end

    NotificationService.create(
      shop: shop,
      title: "Product Listing Complete",
      message: summary,
      category: "product_listing",
      metadata: {
        product_id: product.id,
        results: results
      }
    )
  end
end
