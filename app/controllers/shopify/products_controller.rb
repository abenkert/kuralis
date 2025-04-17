module Shopify
  class ProductsController < Shopify::BaseController
    def index
      @shop = current_shop
      @products = @shop.shopify_products
                      .order(created_at: :desc)
                      .page(params[:page])
                      .per(25)
    end

    def end_product
      @product = current_shop.shopify_products.find(params[:id])

      if @product
        Shopify::EndProductJob.perform_later(current_shop.id, @product.id)

        respond_to do |format|
          format.html do
            action_type = @product.shop.shopify_archive_products? ? "archived" : "deleted"
            flash[:notice] = "Shopify product will be #{action_type}. This may take a moment."
            redirect_to shopify_products_path
          end
          format.turbo_stream do
            action_type = @product.shop.shopify_archive_products? ? "archived" : "deleted"
            flash.now[:notice] = "Shopify product will be #{action_type}. This may take a moment."
          end
          format.json { render json: { message: "Ending product" }, status: :ok }
        end
      else
        respond_to do |format|
          format.html do
            flash[:alert] = "Product not found."
            redirect_to shopify_products_path
          end
          format.turbo_stream do
            flash.now[:alert] = "Product not found."
          end
          format.json { render json: { error: "Product not found" }, status: :not_found }
        end
      end
    end
  end
end
