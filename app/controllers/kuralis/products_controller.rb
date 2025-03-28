module Kuralis
  class ProductsController < AuthenticatedController
    layout "authenticated"

    def index
      @filter = params[:filter] || "all"
      @collector = Kuralis::Collector.new(current_shop.id, params).gather_data

      # Add filtering for draft products
      if @filter == "draft"
        @products = current_shop.kuralis_products.draft.order(created_at: :desc).page(params[:page]).per(20)
      else
        @products = @collector.products
      end
    end

    def new
      # Check if we're editing a draft product
      if params[:draft_id].present?
        @product = current_shop.kuralis_products.draft.find(params[:draft_id])
        @editing_draft = true
      else
        @product = KuralisProduct.new
        @product.build_ebay_product_attribute
      end
    end

    def create
      @product = current_shop.kuralis_products.new(product_params)
      @product.source_platform = "kuralis"

      # If this was a draft product, mark it as finalized
      if params[:draft_id].present?
        draft = current_shop.kuralis_products.draft.find(params[:draft_id])
        @product.ai_product_analysis_id = draft.ai_product_analysis_id

        # Copy over images if the new product doesn't have any
        if !@product.images.attached? && draft.images.attached?
          draft.images.each do |image|
            @product.images.attach(image.blob)
          end
        end

        # Delete the draft if successful
        if @product.save
          draft.destroy
          redirect_to kuralis_products_path, notice: "Product was successfully created from draft."
        else
          render :new, status: :unprocessable_entity
        end
      else
        # Normal product creation flow
        if @product.save
          redirect_to kuralis_products_path, notice: "Product was successfully created."
        else
          render :new, status: :unprocessable_entity
        end
      end
    end

    def edit
      @product = current_shop.kuralis_products.find(params[:id])
      @product.build_ebay_product_attribute unless @product.ebay_product_attribute
    end

    def update
      @product = current_shop.kuralis_products.find(params[:id])

      # Handle image deletion
      if params[:kuralis_product] && params[:kuralis_product][:images_to_delete].present?
        params[:kuralis_product][:images_to_delete].each do |image_id|
          image = @product.images.find_by(id: image_id)
          image.purge if image
        end
      end

      # If updating a draft, mark it as finalized
      if @product.draft? && params[:finalize] == "true"
        @product.assign_attributes(product_params)
        @product.is_draft = false

        if @product.save
          redirect_to kuralis_products_path, notice: "Draft product was successfully finalized."
        else
          render :edit, status: :unprocessable_entity
        end
      else
        if @product.update(product_params)
          redirect_to kuralis_products_path, notice: "Product was successfully updated."
        else
          render :edit, status: :unprocessable_entity
        end
      end
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
        :title, :sku, :description, :base_price, :base_quantity, :weight_oz,
        :brand, :condition, :location, :tags, :warehouse_id,
        images: [], images_to_delete: [],
        ebay_product_attribute_attributes: [
          :id, :category_id, :store_category_id, :condition_id, :condition_description,
          :listing_duration, :shipping_profile_id, :return_profile_id, :payment_profile_id,
          :best_offer_enabled,
          { item_specifics: {} }
        ]
      )
    end
  end
end
