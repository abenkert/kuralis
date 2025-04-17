module Shopify
  class SynchronizationsController < Shopify::BaseController
    def create
      Shopify::ImportProductsJob.perform_later(current_shop.id)
      
      respond_to do |format|
        format.html do
          flash[:notice] = 'Syncing Shopify products. This may take a few minutes.'
          redirect_to shopify_products_path
        end
        format.turbo_stream do
          flash.now[:notice] = 'Syncing Shopify products. This may take a few minutes.'
        end
      end
    end
  end
end 