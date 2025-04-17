module Ebay
  class ShippingPoliciesController < Ebay::BaseController
    def create
      ImportShippingPoliciesJob.perform_later(current_shop.id)
      
      respond_to do |format|
        format.html do
          flash[:notice] = 'Fetching eBay shipping policies...'
          redirect_to settings_path
        end
        format.turbo_stream do
          flash.now[:notice] = 'Fetching eBay shipping policies...'
        end
      end
    end
  end
end 