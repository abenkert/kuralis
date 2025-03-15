module Kuralis
  class ProductsController < AuthenticatedController
    layout 'authenticated'

    def index
      @filter = params[:filter] || 'all'
      @collector = Kuralis::Collector.new(current_shop.id, params).gather_data
      
      # Add filtering for draft products
      if @filter == 'draft'
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
      @product.source_platform = 'kuralis'
      
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
      if @product.draft? && params[:finalize] == 'true'
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

    def bulk_ai_creation
      @pending_analyses = current_shop.ai_product_analyses.pending&.limit(10)
      @processing_analyses = current_shop.ai_product_analyses.processing&.limit(10)
      @completed_analyses = current_shop.ai_product_analyses.completed.unprocessed&.limit(20)
      @draft_products = current_shop.kuralis_products.draft&.limit(20)
    end
    
    # GET /kuralis/products/ai_analysis_status
    def ai_analysis_status
      analysis = current_shop.ai_product_analyses.find(params[:analysis_id])
      
      render json: analysis.as_json_with_details
    end
    
    # GET /kuralis/products/create_product_from_ai
    def create_product_from_ai
      analysis = current_shop.ai_product_analyses.find(params[:analysis_id])
      
      unless analysis.completed?
        respond_to do |format|
          format.html { redirect_to bulk_ai_creation_kuralis_products_path, alert: "Analysis is not yet complete." }
          format.json { render json: { error: "Analysis not complete" }, status: :unprocessable_entity }
        end
        return
      end
      
      # Check if a draft product already exists for this analysis
      existing_product = KuralisProduct.find_by(ai_product_analysis_id: analysis.id, is_draft: true)
      if existing_product.present?
        # Redirect to edit the existing draft product
        respond_to do |format|
          format.html { redirect_to edit_kuralis_product_path(existing_product, finalize: true), notice: "Editing existing draft product." }
          format.json { render json: { redirect: edit_kuralis_product_path(existing_product, finalize: true) } }
        end
        return
      end
      
      # Create a draft product from the analysis
      draft_product = KuralisProduct.create_from_ai_analysis(analysis, current_shop)
      
      if draft_product.persisted?
        # Redirect to edit the draft product
        respond_to do |format|
          format.html { redirect_to edit_kuralis_product_path(draft_product, finalize: true), notice: "Draft product created. Please review and finalize it." }
          format.json { render json: { redirect: edit_kuralis_product_path(draft_product, finalize: true) } }
        end
      else
        error_messages = draft_product.errors.full_messages
        
        # If draft_product has an ebay_product_attribute, include its errors too
        if draft_product.ebay_product_attribute&.errors&.any?
          error_messages += draft_product.ebay_product_attribute.errors.full_messages
        end
        
        # Handle failure
        respond_to do |format|
          format.html { redirect_to bulk_ai_creation_kuralis_products_path, alert: "Failed to create draft product: #{error_messages.join(', ')}" }
          format.json { render json: { error: error_messages }, status: :unprocessable_entity }
        end
      end
    end

    # POST /kuralis/products/upload_images
    def upload_images
      Rails.logger.debug "Upload images params: #{params.inspect}"
      
      # Check for the presence of files
      if params[:images].blank?
        Rails.logger.warn "No images found in params"
        redirect_to bulk_ai_creation_kuralis_products_path, alert: "Please select at least one image to upload."
        return
      end
      
      # Debug the images parameter
      if params[:images].respond_to?(:each)
        Rails.logger.debug "Images is enumerable: #{params[:images].class}"
      else
        Rails.logger.debug "Images is not enumerable: #{params[:images].class}"
      end
      
      # Parse the uploaded files
      uploaded_files = []
      
      # Handle array parameter (multiple files)
      if params[:images].is_a?(Array)
        Rails.logger.debug "Images is an array with #{params[:images].length} items"
        uploaded_files = params[:images]
      
      # Handle hash parameter (Rails wraps parameters as a hash with keys '0', '1', etc.)
      elsif params[:images].is_a?(Hash) || params[:images].is_a?(ActionController::Parameters)
        Rails.logger.debug "Images is a hash/params with #{params[:images].keys.length} keys"
        uploaded_files = params[:images].values
      
      # Handle single file upload
      elsif params[:images].is_a?(ActionDispatch::Http::UploadedFile)
        Rails.logger.debug "Images is a single UploadedFile"
        uploaded_files = [params[:images]]
      
      # Try to handle any other case
      else
        Rails.logger.debug "Images is some other type, attempting to process"
        begin
          uploaded_files = Array(params[:images])
        rescue => e
          Rails.logger.error "Failed to convert images to array: #{e.message}"
        end
      end
      
      Rails.logger.debug "Found #{uploaded_files.length} files to process"
      
      # Process each file
      successful_uploads = 0
      failed_uploads = 0
      
      uploaded_files.each_with_index do |uploaded_file, index|
        begin
          # Skip if not a file object
          unless uploaded_file.respond_to?(:original_filename) && uploaded_file.respond_to?(:read)
            Rails.logger.warn "Item #{index} is not a valid file object: #{uploaded_file.class}"
            next
          end
          
          Rails.logger.debug "Processing file #{index}: #{uploaded_file.original_filename}"
          
          # Create and save the analysis record
          analysis = current_shop.ai_product_analyses.new(
            status: 'pending',
            image: uploaded_file.original_filename # Set the database column
          )
          
          # Attach the image to the record using Active Storage
          analysis.image_attachment.attach(uploaded_file)
          
          if analysis.save
            Rails.logger.debug "Successfully created analysis record for #{uploaded_file.original_filename}"
            successful_uploads += 1
            
            # Queue the analysis job with the shop_id
            AiProductAnalysisJob.perform_later(current_shop.id, analysis.id)
          else
            Rails.logger.error "Failed to save analysis: #{analysis.errors.full_messages.join(', ')}"
            failed_uploads += 1
          end
        rescue => e
          Rails.logger.error "Error processing file #{index}: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          failed_uploads += 1
        end
      end
      
      # Redirect with appropriate message
      if successful_uploads > 0
        message = "#{successful_uploads} #{'image'.pluralize(successful_uploads)} uploaded and queued for analysis."
        message += " #{failed_uploads} #{'upload'.pluralize(failed_uploads)} failed." if failed_uploads > 0
        
        redirect_to bulk_ai_creation_kuralis_products_path, notice: message
      else
        redirect_to bulk_ai_creation_kuralis_products_path, alert: "No images were uploaded. Please try again."
      end
    end
    
    # DELETE /kuralis/products/remove_image
    def remove_image
      analysis = current_shop.ai_product_analyses.find(params[:analysis_id])
      
      if analysis.destroy
        respond_to do |format|
          format.html { redirect_to bulk_ai_creation_kuralis_products_path, notice: "Image removed successfully." }
          format.json { head :no_content }
          format.turbo_stream {
            flash.now[:notice] = "Image removed successfully."
            render turbo_stream: [
              turbo_stream.remove("analysis_#{analysis.id}"),
              turbo_stream.prepend("flash", partial: "shared/flash")
            ]
          }
        end
      else
        respond_to do |format|
          format.html { redirect_to bulk_ai_creation_kuralis_products_path, alert: "Failed to remove image." }
          format.json { render json: analysis.errors, status: :unprocessable_entity }
          format.turbo_stream {
            flash.now[:alert] = "Failed to remove image."
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
        :is_draft,
        :ai_product_analysis_id,
        images: [], 
        images_to_delete: [],
        tags: [], 
        product_attributes: {},
        ebay_product_attribute_attributes: [
          :id,
          :condition_id,
          :condition_description,
          :category_id,
          :store_category_id,
          :shipping_profile_id,
          :listing_duration,
          :best_offer_enabled,
          item_specifics: {}
        ]
      )
    end
  end
end
