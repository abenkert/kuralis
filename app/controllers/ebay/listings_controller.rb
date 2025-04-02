module Ebay
  class ListingsController < Ebay::BaseController
    def index
      @shop = current_shop
      @listings = @shop.shopify_ebay_account.ebay_listings
                            .order(created_at: :desc)
                            .page(params[:page])
                            .per(25) # Adjust number per page as needed
    end

    def end_listing
      @listing = current_shop.shopify_ebay_account.ebay_listings.find(params[:id])

      if @listing
        Ebay::EndListingJob.perform_later(@listing.id, params[:reason] || "NotAvailable")

        respond_to do |format|
          format.html do
            flash[:notice] = "eBay listing will be ended. This may take a moment."
            redirect_to ebay_listings_path
          end
          format.turbo_stream do
            flash.now[:notice] = "eBay listing will be ended. This may take a moment."
          end
          format.json { render json: { message: "Ending listing" }, status: :ok }
        end
      else
        respond_to do |format|
          format.html do
            flash[:alert] = "Listing not found."
            redirect_to ebay_listings_path
          end
          format.turbo_stream do
            flash.now[:alert] = "Listing not found."
          end
          format.json { render json: { error: "Listing not found" }, status: :not_found }
        end
      end
    end
  end
end
