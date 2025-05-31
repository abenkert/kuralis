module Kuralis
  class ProductsController < AuthenticatedController
    layout "authenticated"

    def index
      @filter = params[:filter] || "all"

      # Initialize base query
      @query = params[:query]
      @search_by = params[:search_by] || "all"

      # First get the base product collection
      if @filter == "draft"
        base_query = current_shop.kuralis_products.draft.order(created_at: :desc)
      else
        # Let the collector gather filtered products
        @collector = Kuralis::Collector.new(current_shop.id, params).gather_data
        base_query = @collector.products.except(:page, :per)
      end

      # Apply search if query is present
      if @query.present?
        case @search_by
        when "title"
          base_query = base_query.where("kuralis_products.title ILIKE ?", "%#{@query}%")
        when "location"
          base_query = base_query.where("kuralis_products.location ILIKE ?", "%#{@query}%")
        when "description"
          base_query = base_query.where("kuralis_products.description ILIKE ?", "%#{@query}%")
        else # "all" or any other value
          base_query = base_query.where("kuralis_products.title ILIKE ? OR kuralis_products.location ILIKE ? OR kuralis_products.description ILIKE ?",
                                    "%#{@query}%", "%#{@query}%", "%#{@query}%")
        end
      end

      # Paginate the final results
      @products = base_query.page(params[:page]).per(20)
    end

    def new
      # Check if we're editing a draft product
      if params[:draft_id].present?
        @product = current_shop.kuralis_products.draft.find(params[:draft_id])
        @editing_draft = true
      else
        @product = KuralisProduct.new
        # Build eBay product attribute with default values
        ebay_attr = @product.build_ebay_product_attribute

        # Apply default values from shop settings
        ebay_attr.condition_id = current_shop.get_setting(KuralisShopSetting::CATEGORIES[:ebay], "default_condition")
        ebay_attr.listing_duration = current_shop.get_setting(KuralisShopSetting::CATEGORIES[:ebay], "default_duration")
        ebay_attr.shipping_profile_id = current_shop.get_setting(KuralisShopSetting::CATEGORIES[:ebay], "default_shipping_policy")
        ebay_attr.payment_profile_id = current_shop.get_setting(KuralisShopSetting::CATEGORIES[:ebay], "default_payment_policy")
        ebay_attr.return_profile_id = current_shop.get_setting(KuralisShopSetting::CATEGORIES[:ebay], "default_return_policy")
        ebay_attr.best_offer_enabled = true # Default to enabled
      end
    end

    def create
      @product = current_shop.kuralis_products.new(product_params)
      @product.source_platform = "kuralis"

      # Flag to track if we should list on eBay immediately
      list_on_ebay = params[:list_on_ebay].present?

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
          # Check if we should try to list on eBay
          if list_on_ebay
            handle_ebay_listing(@product)
          end

          draft.destroy
          redirect_to kuralis_products_path, notice: "Product was successfully created from draft."
        else
          render :new, status: :unprocessable_entity
        end
      else
        # Normal product creation flow
        if @product.save
          # Check if we should try to list on eBay
          if list_on_ebay
            handle_ebay_listing(@product)
          end

          redirect_to kuralis_products_path, notice: "Product was successfully created."
        else
          render :new, status: :unprocessable_entity
        end
      end
    end

    def edit
      @product = current_shop.kuralis_products.find(params[:id])

      # Build eBay product attribute with defaults if it doesn't exist
      unless @product.ebay_product_attribute
        ebay_attr = @product.build_ebay_product_attribute

        # Apply default values from shop settings
        ebay_attr.condition_id = current_shop.get_setting(KuralisShopSetting::CATEGORIES[:ebay], "default_condition")
        ebay_attr.listing_duration = current_shop.get_setting(KuralisShopSetting::CATEGORIES[:ebay], "default_duration")
        ebay_attr.shipping_profile_id = current_shop.get_setting(KuralisShopSetting::CATEGORIES[:ebay], "default_shipping_policy")
        ebay_attr.payment_profile_id = current_shop.get_setting(KuralisShopSetting::CATEGORIES[:ebay], "default_payment_policy")
        ebay_attr.return_profile_id = current_shop.get_setting(KuralisShopSetting::CATEGORIES[:ebay], "default_return_policy")
        ebay_attr.best_offer_enabled = true # Default to enabled
      end
    end

    def update
      @product = current_shop.kuralis_products.find(params[:id])
      product_attrs = product_params

      # Handle inventory transactions for manual quantity changes
      if product_attrs[:base_quantity].present? && @product.base_quantity != product_attrs[:base_quantity].to_i
        old_quantity = @product.base_quantity
        new_quantity = product_attrs[:base_quantity].to_i
        quantity_change = new_quantity - old_quantity

        # Create a manual adjustment transaction
        InventoryTransaction.create!(
          kuralis_product: @product,
          quantity: quantity_change,
          transaction_type: "manual_adjustment",
          previous_quantity: old_quantity,
          new_quantity: new_quantity,
          notes: "Manual inventory adjustment via UI",
          processed: false
        )
      end

      # Handle image deletions
      if params[:kuralis_product] && params[:kuralis_product][:images_to_delete].present?
        params[:kuralis_product][:images_to_delete].each do |image_id|
          image = @product.images.find_by(id: image_id)
          image.purge if image
        end
      end

      # Remove images_to_delete from attributes since it's not a real attribute
      product_attrs.delete(:images_to_delete)

      # Handle images separately - this is key to preserving existing images
      new_images = product_attrs.delete(:images)

      # Only attach new images if they exist (any non-blank files)
      if new_images.present? && new_images.any?(&:present?)
        Rails.logger.debug "Attaching #{new_images.count(&:present?)} new images to existing product"

        # Only attach the non-blank images
        new_images.each do |image|
          @product.images.attach(image) if image.present?
        end
      end

      # Handle tag conversion
      if product_attrs[:tags].is_a?(String)
        product_attrs[:tags] = product_attrs[:tags].split(",").map(&:strip)
      end

      # If updating a draft, mark it as finalized
      if @product.draft? && params[:finalize] == "true"
        @product.assign_attributes(product_attrs)
        @product.is_draft = false

        if @product.save
          # Check if user wants to finalize and list on platforms
          if params[:finalize_and_list] == "true"
            selected_platforms = params[:platforms] || []

            if selected_platforms.any?
              # Use the ListingService to create listings on selected platforms
              listing_service = ListingService.new(
                shop: current_shop,
                product: @product,
                platforms: selected_platforms
              )

              listing_results = listing_service.create_listings

              # Generate feedback message based on results
              successful_platforms = listing_results.select { |_, result| result[:success] }.keys
              failed_platforms = listing_results.select { |_, result| !result[:success] }.keys

              if successful_platforms.any? && failed_platforms.empty?
                success_message = "Product finalized and successfully listed on #{successful_platforms.join(' and ')}."
              elsif successful_platforms.any? && failed_platforms.any?
                success_message = "Product finalized and listed on #{successful_platforms.join(' and ')}. Failed to list on #{failed_platforms.join(' and ')} - check notifications for details."
              elsif failed_platforms.any?
                success_message = "Product finalized but failed to list on #{failed_platforms.join(' and ')} - check notifications for details."
              else
                success_message = "Product finalized successfully."
              end
            else
              success_message = "Product finalized successfully."
            end
          else
            success_message = "Product finalized successfully."
          end

          # Check if this is part of a finalization sequence
          if params[:sequence] == "true" && session[:draft_finalize_remaining].present?
            # Decrement remaining count
            session[:draft_finalize_remaining] -= 1

            # If there are more drafts, go to the next one
            if session[:draft_finalize_remaining] > 0
              next_draft = current_shop.kuralis_products.draft.order(created_at: :asc).first
              if next_draft
                redirect_to edit_kuralis_product_path(next_draft, finalize: true, sequence: true),
                             notice: success_message + " Moving to next draft product."
                return
              end
            end

            # All done or no more drafts found
            total = session[:draft_finalize_total] || 0
            session[:draft_finalize_total] = nil
            session[:draft_finalize_remaining] = nil
            redirect_to kuralis_products_path, notice: "Successfully finalized #{total} draft products!"
          else
            redirect_to kuralis_products_path, notice: success_message
          end
        else
          render :edit, status: :unprocessable_entity
        end
      else
        if @product.update(product_attrs)
          # Check if we should list on eBay
          if params[:list_on_ebay].present? && !@product.listed_on_ebay?
            handle_ebay_listing(@product)
          end

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

    # Handle the eBay listing process
    def handle_ebay_listing(product)
      # Validate eBay attributes
      ebay_errors = product.validate_for_ebay_listing

      if ebay_errors.empty?
        # Apply default eBay settings if needed
        if product.ebay_product_attribute
          ebay_attr = product.ebay_product_attribute

          # Apply default shipping policy if not set
          if ebay_attr.shipping_profile_id.blank?
            default_shipping = current_shop.get_setting(KuralisShopSetting::CATEGORIES[:ebay], "default_shipping_policy")
            ebay_attr.update(shipping_profile_id: default_shipping) if default_shipping.present?
          end

          # Apply default payment policy if not set
          if ebay_attr.payment_profile_id.blank?
            default_payment = current_shop.get_setting(KuralisShopSetting::CATEGORIES[:ebay], "default_payment_policy")
            ebay_attr.update(payment_profile_id: default_payment) if default_payment.present?
          end

          # Apply default return policy if not set
          if ebay_attr.return_profile_id.blank?
            default_return = current_shop.get_setting(KuralisShopSetting::CATEGORIES[:ebay], "default_return_policy")
            ebay_attr.update(return_profile_id: default_return) if default_return.present?
          end

          # Apply default condition if not set
          if ebay_attr.condition_id.blank?
            default_condition = current_shop.get_setting(KuralisShopSetting::CATEGORIES[:ebay], "default_condition")
            ebay_attr.update(condition_id: default_condition) if default_condition.present?
          end

          # Apply default listing duration if not set
          if ebay_attr.listing_duration.blank?
            default_duration = current_shop.get_setting(KuralisShopSetting::CATEGORIES[:ebay], "default_duration")
            ebay_attr.update(listing_duration: default_duration) if default_duration.present?
          end
        end

        # Schedule an eBay listing job
        Ebay::CreateListingJob.perform_later(shop_id: current_shop.id, kuralis_product_id: product.id)
        flash[:notice] = "Product created and eBay listing scheduled."
      else
        # Product was created but couldn't be listed on eBay
        error_messages = ebay_errors.join(", ")
        flash[:alert] = "Product was created but could not be listed on eBay: #{error_messages}. Please update the eBay information and try listing again."
      end
    end
  end
end
