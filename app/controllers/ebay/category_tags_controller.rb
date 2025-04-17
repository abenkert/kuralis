module Ebay
  class CategoryTagsController < Ebay::BaseController
    def update
      ebay_account = current_shop.shopify_ebay_account
      
      params[:tags].each do |category_id, tag|
        if tag.present?
          ebay_account.set_category_tag(category_id, tag)
        else
          ebay_account.remove_category_tag(category_id)
        end
      end

      if ebay_account.save
        respond_to do |format|
          format.html do
            flash[:notice] = 'Category tags updated successfully'
            redirect_to settings_path
          end
          format.turbo_stream do
            flash.now[:notice] = 'Category tags updated successfully'
          end
        end
      else
        respond_to do |format|
          format.html do
            flash[:alert] = 'Failed to update category tags'
            redirect_to settings_path
          end
          format.turbo_stream do
            flash.now[:alert] = 'Failed to update category tags'
          end
        end
      end
    end
  end
end 