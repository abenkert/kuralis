module Ebay
  class StoreCategoriesController < Ebay::BaseController
    def create
      ImportStoreCategoriesJob.perform_later(current_shop.id)
      
      respond_to do |format|
        format.html do
          flash[:notice] = 'Fetching eBay store categories...'
          redirect_to settings_path
        end
        format.turbo_stream do
          flash.now[:notice] = 'Fetching eBay store categories...'
        end
      end
    end
  end
end 