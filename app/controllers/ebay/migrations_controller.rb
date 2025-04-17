module Ebay
  class MigrationsController < Ebay::BaseController
    def create
      listing_ids = if params[:migrate_all] == 'true'
        # Get all unmigrated listing IDs from the database
        current_shop.shopify_ebay_account
                   .ebay_listings
                   .left_joins(:kuralis_product)
                   .where(kuralis_products: { id: nil })
                   .pluck(:id)
      else
        params[:listing_ids]
      end
      
      if listing_ids.present?
        MigrateEbayListingsJob.perform_later(current_shop.id, listing_ids)
        
        respond_to do |format|
          format.html do
            flash[:notice] = 'Migration started. This may take a few minutes.'
            redirect_to ebay_listings_path
          end
          format.turbo_stream do
            flash.now[:notice] = 'Migration started. This may take a few minutes.'
          end
        end
      else
        respond_to do |format|
          format.html do
            flash[:alert] = 'No listings available to migrate.'
            redirect_to ebay_listings_path
          end
          format.turbo_stream do
            flash.now[:alert] = 'No listings available to migrate.'
          end
        end
      end
    end

    # Add endpoint to get count of unmigrated listings
    def unmigrated_count
      # Query for listings that don't have an associated kuralis_product
      count = current_shop.shopify_ebay_account
                         .ebay_listings
                         .left_joins(:kuralis_product)
                         .where(kuralis_products: { id: nil })
                         .count
      
      render json: { count: count }
    end
  end
end 