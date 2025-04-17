module Ebay
  class ShippingWeightsController < Ebay::BaseController
    def update
      ebay_account = current_shop.shopify_ebay_account
      
      params[:weights].each do |profile_id, weight|
        ebay_account.set_shipping_profile_weight(profile_id, weight)
      end

      if ebay_account.save
        respond_to do |format|
          format.html do
            flash[:notice] = 'Shipping weights updated successfully'
            redirect_to settings_path
          end
          format.turbo_stream do
            flash.now[:notice] = 'Shipping weights updated successfully'
          end
        end
      else
        respond_to do |format|
          format.html do
            flash[:alert] = 'Failed to update shipping weights'
            redirect_to settings_path
          end
          format.turbo_stream do
            flash.now[:alert] = 'Failed to update shipping weights'
          end
        end
      end
    end
  end
end 