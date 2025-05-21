module Ebay
  class ListingsController < Ebay::BaseController
    def index
      @shop = current_shop
      base_query = @shop.shopify_ebay_account.ebay_listings

      # Handle search query
      if params[:query].present?
        search_term = "%#{params[:query]}%"

        case params[:search_by]
        when "title"
          base_query = base_query.where("title ILIKE ?", search_term)
        when "ebay_item_id"
          base_query = base_query.where("ebay_item_id ILIKE ?", search_term)
        when "sku"
          base_query = base_query.where("sku ILIKE ?", search_term)
        else # "all" or any other value
          base_query = base_query.where("title ILIKE ? OR ebay_item_id ILIKE ? OR sku ILIKE ?",
                                    search_term, search_term, search_term)
        end
      end

      # Handle status filter
      if params[:status].present?
        case params[:status]
        when "active"
          base_query = base_query.where(ebay_status: "active")
        when "ended"
          base_query = base_query.where.not(ebay_status: "active")
        when "migrated"
          base_query = base_query.joins("INNER JOIN kuralis_products ON kuralis_products.id = ebay_listings.kuralis_product_id")
        when "not_migrated"
          base_query = base_query.where(kuralis_product_id: nil)
        end
      end

      # Apply ordering and pagination
      @listings = base_query.order(created_at: :desc)
                            .page(params[:page])
                            .per(25) # Adjust number per page as needed
    end

    def end_listing
      @listing = current_shop.shopify_ebay_account.ebay_listings.find(params[:id])

      if @listing
        Ebay::EndListingJob.perform_later(current_shop.id, @listing.id, params[:reason] || "NotAvailable")

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
