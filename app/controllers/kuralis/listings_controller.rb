module Kuralis
  ############################################################
  # This controller is used to list kuralis products on a platform
  ############################################################
  class ListingsController < AuthenticatedController
    def create
      @product = current_shop.kuralis_products.find(params[:product_id])
      platforms = params[:platforms] || []

      if platforms.empty?
        redirect_to kuralis_product_path(@product), alert: "Please select a platform for listing."
        return
      end

      service = ListingService.new(
        shop: current_shop,
        product: @product,
        platforms: platforms
      )

      results = service.create_listings

      success_count = results.count { |_, r| r[:success] }
      total_count = results.size

      if success_count == total_count
        redirect_to kuralis_product_path(@product), notice: "Product successfully listed on #{platforms.join(' and ')}."
      elsif success_count > 0
        redirect_to kuralis_product_path(@product), notice: "Product listed on some platforms. Check notifications for details."
      else
        redirect_to kuralis_product_path(@product), alert: "Failed to list product. Check notifications for details."
      end
    end
  end
end
