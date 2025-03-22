module Kuralis
  class BulkListingsController < AuthenticatedController
    def index
      @platform = params[:platform]
      @platforms_available = %w[shopify ebay]

      # Query products unlisted on the selected platform
      case @platform
      when "shopify"
        @products = current_shop.kuralis_products.where(shopify_product_id: nil)
      when "ebay"
        @products = current_shop.kuralis_products.where(ebay_listing_id: nil)
      when "all"
        # Products unlisted on any platform
        @products = current_shop.kuralis_products.unlinked
      else
        # Default to showing all products
        @products = current_shop.kuralis_products
      end

      @total_count = @products.count
      @products = @products.order(created_at: :desc).page(params[:page]).per(100)
    end

    def create
      platforms = params[:platforms] || []

      # Ensure at least one platform is selected
      if platforms.empty?
        redirect_to bulk_listing_kuralis_products_path, alert: "Please select at least one platform for listing."
        return
      end

      if params[:select_all_records] == "1"
        # Get all product IDs except deselected ones
        deselected_ids = JSON.parse(params[:deselected_ids] || "[]")

        # Find eligible products for each platform and get the intersection
        product_ids = []

        if platforms.include?("shopify")
          shopify_ids = current_shop.kuralis_products.where(shopify_product_id: nil).pluck(:id)
          product_ids = product_ids.empty? ? shopify_ids : product_ids & shopify_ids
        end

        if platforms.include?("ebay")
          ebay_ids = current_shop.kuralis_products.where(ebay_listing_id: nil).pluck(:id)
          product_ids = product_ids.empty? ? ebay_ids : product_ids & ebay_ids
        end

        # Remove deselected products
        product_ids = product_ids - deselected_ids
      else
        product_ids = params[:product_ids] || []
      end

      if product_ids.empty?
        redirect_to kuralis_products_path, alert: "No eligible products selected for listing."
        return
      end

      BulkListingJob.perform_later(
        shop_id: current_shop.id,
        product_ids: product_ids,
        platforms: platforms
      )

      redirect_to kuralis_products_path,
                  notice: "Bulk listing process started for #{product_ids.count} products on #{platforms.join(' and ')}. You'll be notified when complete."
    end
  end
end
