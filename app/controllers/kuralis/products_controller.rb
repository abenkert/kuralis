module Kuralis
  class ProductsController < AuthenticatedController
    layout 'authenticated'

    def index
      @filter = params[:filter] || 'all'
      @collector = Kuralis::Collector.new(current_shop.id, params).gather_data
      @products = @collector.products
    end

    def new
      @product = KuralisProduct.new
      @product.build_ebay_product_attribute
    end

    def create
      @product = current_shop.kuralis_products.new(product_params)
      @product.source_platform = 'manual'
      
      if @product.save
        redirect_to kuralis_products_path, notice: "Product was successfully created."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def bulk_listing
      @platform = params[:platform]
      @total_count = current_shop.kuralis_products
                            .where(
                              case @platform
                              when 'shopify'
                                { shopify_product_id: nil }
                              when 'ebay'
                                { ebay_listing_id: nil }
                              end
                            ).count
  
      @products = current_shop.kuralis_products
                             .where(
                               case @platform
                               when 'shopify'
                                 { shopify_product_id: nil }
                               when 'ebay'
                                 { ebay_listing_id: nil }
                               end
                             )
                             .order(created_at: :desc)
                             .page(params[:page])
                             .per(100)
    end

    def process_bulk_listing
      platform = params[:platform]
      
      if params[:select_all_records] == '1'
        # Get all product IDs except deselected ones
        deselected_ids = JSON.parse(params[:deselected_ids] || '[]')
        product_ids = current_shop.kuralis_products
                                 .where(
                                   case platform
                                   when 'shopify'
                                     { shopify_product_id: nil }
                                   when 'ebay'
                                     { ebay_listing_id: nil }
                                   end
                                 )
                                 .where.not(id: deselected_ids)
                                 .pluck(:id)
      else
        product_ids = params[:product_ids] || []
      end

      BulkListingJob.perform_later(
        shop_id: current_shop.id,
        product_ids: product_ids,
        platform: platform
      )

      redirect_to kuralis_products_path, 
                  notice: "Bulk listing process started for #{product_ids.count} products. You'll be notified when complete."
    end

    def destroy
      @product = KuralisProduct.find(params[:id])
      
      if @product.destroy
        respond_to do |format|
          format.html { redirect_to kuralis_products_path, notice: "Product was successfully deleted." }
          format.json { head :no_content }
          format.turbo_stream { 
            flash.now[:notice] = "Product was successfully deleted."
            render turbo_stream: [
              turbo_stream.remove(@product),
              turbo_stream.prepend("flash", partial: "shared/flash")
            ]
          }
        end
      else
        respond_to do |format|
          format.html { redirect_to kuralis_products_path, alert: "Failed to delete product." }
          format.json { render json: @product.errors, status: :unprocessable_entity }
          format.turbo_stream {
            flash.now[:alert] = "Failed to delete product."
            render turbo_stream: turbo_stream.prepend("flash", partial: "shared/flash")
          }
        end
      end
    end

    private

    def product_params
      params.require(:kuralis_product).permit(
        :title, 
        :description, 
        :base_price, 
        :base_quantity, 
        :sku, 
        :brand, 
        :condition, 
        :location, 
        :weight_oz,
        images: [], 
        tags: [], 
        product_attributes: {},
        ebay_product_attribute_attributes: [
          :id,
          :category_id,
          :store_category_id,
          :condition_id,
          :condition_description,
          :listing_duration,
          :shipping_profile_id,
          :best_offer_enabled,
          item_specifics: {}
        ]
      )
    end
  end
end
