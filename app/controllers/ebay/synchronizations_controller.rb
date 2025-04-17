module Ebay
  class SynchronizationsController < Ebay::BaseController
    def create
      ImportEbayListingsJob.perform_later(current_shop.id)
      
      respond_to do |format|
        format.html do
          flash[:notice] = 'Syncing eBay listings. This may take a few minutes.'
          redirect_to ebay_listings_path
        end
        format.turbo_stream do
          flash.now[:notice] = 'Syncing eBay listings. This may take a few minutes.'
        end
      end
    end
  end
end 