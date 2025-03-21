module Ebay
  class ListingsController < Ebay::BaseController
    def index
      @shop = current_shop
      @listings = @shop.shopify_ebay_account.ebay_listings
                            .order(created_at: :desc)
                            .page(params[:page])
                            .per(25) # Adjust number per page as needed
    end
  end
end
