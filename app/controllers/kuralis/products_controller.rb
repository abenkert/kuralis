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
      @product.source_platform = 'kuralis'
      
      # Handle AI analysis image if needed
      if params[:ai_analysis_id].present? && params[:attach_analysis_image] == 'true'
        analysis = current_shop.ai_product_analyses.find_by(id: params[:ai_analysis_id])
        if analysis&.image_attachment&.attached?
          @product.images.attach(analysis.image_attachment.blob)
          Rails.logger.debug "Attached image from analysis to product: #{analysis.id}"
        end
      end
      
      if @product.save
        if params[:ai_analysis_id].present?
          analysis = current_shop.ai_product_analyses.find_by(id: params[:ai_analysis_id])
          analysis.mark_as_processed! if analysis
        end
        redirect_to kuralis_products_path, notice: "Product was successfully created."
      else
        # If this was an AI-assisted creation and failed, maintain AI context
        if params[:ai_analysis_id].present?
          @ai_assisted = true
          @ai_analysis_id = params[:ai_analysis_id]
          analysis = current_shop.ai_product_analyses.find_by(id: params[:ai_analysis_id])
          
          if analysis&.image_attachment&.attached?
            @image_from_analysis = {
              url: url_for(analysis.image_attachment),
              filename: analysis.image_attachment.filename.to_s,
              content_type: analysis.image_attachment.content_type,
              byte_size: analysis.image_attachment.byte_size
            }
          end
          
          # Try to retrieve category info again if needed
          if @product.ebay_product_attribute&.category_id.present?
            ebay_category = EbayCategory.find_by(category_id: @product.ebay_product_attribute.category_id)
            @ai_category_info = ebay_category ? {
              id: ebay_category.category_id,
              name: ebay_category.name,
              full_path: ebay_category.full_path
            } : nil
          end
        end
        
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

    # GET /kuralis/products/bulk_ai_creation
    def bulk_ai_creation
      @pending_analyses = current_shop.ai_product_analyses.pending.recent.limit(10)
      @processing_analyses = current_shop.ai_product_analyses.processing.recent.limit(10)
      @ready_analyses = current_shop.ai_product_analyses.ready_for_products.recent.limit(10)
      @processed_analyses = current_shop.ai_product_analyses.processed.completed.recent.limit(10)
      @failed_analyses = current_shop.ai_product_analyses.failed.recent.limit(10)
      
      # Combine all analyses for the view
      @analyses = (@ready_analyses + @pending_analyses + @processing_analyses + @failed_analyses).sort_by(&:created_at).reverse
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
    
    # GET /kuralis/products/ai_analysis_status
    def ai_analysis_status
      analysis = current_shop.ai_product_analyses.find_by(id: params[:analysis_id])
      
      unless analysis
        render json: { error: "Analysis not found" }, status: :not_found
        return
      end
      
      has_image = analysis.image_attachment.attached?
      image_url = has_image ? url_for(analysis.image_attachment) : nil

      result = {
        id: analysis.id,
        status: analysis.status,
        progress: analysis.progress,
        has_image: has_image,
        image_url: image_url,
        created_at: analysis.created_at,
        updated_at: analysis.updated_at
      }
      
      if analysis.completed?
        result[:results] = analysis.results
      end
      
      respond_to do |format|
        format.json { render json: result }
        format.turbo_stream { 
          render turbo_stream: turbo_stream.replace(
            "analysis_#{analysis.id}", 
            partial: "kuralis/products/ai/analysis_item", 
            locals: { analysis: analysis }
          )
        }
      end
    end
    
    # GET /kuralis/products/create_product_from_ai
    def create_product_from_ai
      analysis = current_shop.ai_product_analyses.find_by(id: params[:analysis_id])

      unless analysis && analysis.completed?
        flash[:alert] = "Analysis is not complete or not found"
        redirect_to bulk_ai_creation_kuralis_products_path
        return
      end

      Rails.logger.debug "Creating product from AI analysis: #{analysis.id}"
      Rails.logger.debug "Analysis results: #{analysis.results.inspect}"
      
      # Create a new product with attributes from the analysis
      @product = current_shop.kuralis_products.new(
        title: analysis.results["title"],
        description: analysis.results["description"],
        brand: analysis.results["brand"],
        condition: map_condition(analysis.results["condition"]),
        base_quantity: 1
      )
      
      # Handle tags - can be either a string or an array
      if analysis.results["tags"].present?
        if analysis.results["tags"].is_a?(Array)
          @product.tags = analysis.results["tags"]
        else
          @product.tags = analysis.results["tags"].to_s.split(/,\s*/)
        end
      end
      
      # Ensure we have a valid ebay_category_id
      ebay_category_id = analysis.results["ebay_category_id"]
      ebay_category_path = analysis.results["ebay_category"]
      
      Rails.logger.debug "eBay category data - ID: #{ebay_category_id}, Path: #{ebay_category_path}"
      
      # Get detailed eBay category information - first try by path if available, then ID
      ebay_category = nil
      
      if ebay_category_path.present?
        ebay_category = find_ebay_category_by_path(ebay_category_path)
        ebay_category_id = ebay_category.category_id if ebay_category
        Rails.logger.debug "Category from path: #{ebay_category.inspect}"
      end
      
      if ebay_category.nil? && ebay_category_id.present?
        ebay_category = EbayCategory.find_by(category_id: ebay_category_id)
        Rails.logger.debug "Category from ID: #{ebay_category.inspect}"
      end
      
      # Build eBay product attributes with the data we have
      ebay_attributes = {
        condition_id: map_ebay_condition_id(analysis.results["condition"]),
        condition_description: generate_condition_description(analysis.results),
        item_specifics: analysis.results["item_specifics"] || {}
      }
      
      # Add category_id if we found a valid category
      ebay_attributes[:category_id] = ebay_category.category_id if ebay_category
      
      # Build the eBay product attribute
      @product.build_ebay_product_attribute(ebay_attributes)
      
      # Load eBay item specifics for the category if available
      @item_specifics = []
      if ebay_category
        begin
          # Try to load category specifics from the eBay API/database
          category_specifics = EbayCategoryItemSpecific.where(ebay_category_id: ebay_category.id)
          
          # If we have AI-provided item specifics, merge them with the category specifics
          ai_item_specifics = analysis.results["item_specifics"] || {}
          
          @item_specifics = category_specifics.map do |specific|
            {
              name: specific.name,
              required: specific.required,
              help_text: specific.help_text,
              value: ai_item_specifics[specific.name] || ''
            }
          end
          
          # Make item specifics available to JavaScript
          @item_specifics_json = @item_specifics.to_json
          
          Rails.logger.debug "Loaded #{@item_specifics.size} item specifics for category"
        rescue => e
          Rails.logger.error "Error loading item specifics: #{e.message}"
        end
      end
      
      # Store image information for the view
      @image_from_analysis = nil
      if analysis.image_attachment.attached?
        @image_from_analysis = {
          url: url_for(analysis.image_attachment),
          filename: analysis.image_attachment.filename.to_s,
          content_type: analysis.image_attachment.content_type,
          byte_size: analysis.image_attachment.byte_size
        }
        Rails.logger.debug "Image from analysis: #{@image_from_analysis[:url]}"
      end
      
      # Set flags for AI-assisted creation
      @ai_assisted = true
      @ai_analysis_id = analysis.id
      @ai_category_info = ebay_category ? {
        id: ebay_category.category_id,
        name: ebay_category.name,
        full_path: ebay_category.full_path
      } : nil
      
      # Mark the analysis as processed - defer until product is actually created
      @analysis_to_mark_processed = analysis
      
      # Render the form with all pre-populated data
      render :new
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

    # Maps the AI-provided condition to the application's condition options
    def map_condition(ai_condition)
      condition_mapping = {
        "New" => "New",
        "Like New" => "Used - Like New",
        "Mint" => "Used - Like New", 
        "Near Mint" => "Used - Very Good",
        "Very Good" => "Used - Very Good",
        "Good" => "Used - Good",
        "Fair" => "Used - Good",
        "Poor" => "Used - Acceptable",
        "Acceptable" => "Used - Acceptable"
      }
      
      # Try to find a match in our mapping
      if ai_condition.present?
        condition_mapping.each do |ai_term, app_term|
          return app_term if ai_condition.downcase.include?(ai_term.downcase)
        end
      end
      
      # Default to "Used - Good" if no match found
      "Used - Good"
    end
    
    # Maps the AI-provided condition to eBay's condition IDs
    def map_ebay_condition_id(ai_condition)
      condition_id_mapping = {
        "New" => "1000",
        "Like New" => "1500",
        "Mint" => "1500",
        "Near Mint" => "2500",
        "Very Good" => "4000",
        "Good" => "5000",
        "Fair" => "5000",
        "Poor" => "6000",
        "Acceptable" => "6000"
      }
      
      # Try to find a match in our mapping
      if ai_condition.present?
        condition_id_mapping.each do |ai_term, condition_id|
          return condition_id if ai_condition.downcase.include?(ai_term.downcase)
        end
      end
      
      # Default to "Used" if no match found
      "3000"
    end

    # Helper method to generate condition description from AI results
    def generate_condition_description(results)
      description = ""
      
      if results["condition"].present?
        description += "Condition: #{results["condition"]}. "
      end
      
      # For comics, add grading details
      if results["publisher"].present?
        description += "#{results["publisher"]} "
        description += "Issue ##{results["issue_number"]} " if results["issue_number"].present?
        description += "(#{results["year"]}) " if results["year"].present?
        
        # Add main characters if available
        if results["characters"].present? && results["characters"].is_a?(Array) && results["characters"].any?
          description += "featuring #{results["characters"].join(", ")}. "
        end
      end
      
      # Add any specific condition notes from item specifics
      if results["item_specifics"].present?
        specific_conditions = results["item_specifics"].select { |k, _| k.to_s.downcase.include?("condition") || k.to_s.downcase.include?("grade") }
        if specific_conditions.any?
          description += "Details: "
          description += specific_conditions.map { |k, v| "#{k}: #{v}" }.join(", ")
        end
      end
      
      description
    end

    # Helper method to find an eBay category by path
    def find_ebay_category_by_path(path)
      return nil if path.blank?
      
      # Extract the leaf category name from the path
      path_parts = path.split('>').map(&:strip)
      leaf_name = path_parts.last
      
      # First try to find by exact leaf name
      categories = EbayCategory.search_by_name(leaf_name).to_a
      
      if categories.any?
        # If we have multiple matches, try to find the best match based on the full path
        if categories.length > 1 && path_parts.length > 1
          # Calculate similarity scores for each category
          best_match = nil
          best_score = 0
          
          categories.each do |category|
            # Get the full path and calculate similarity
            full_path = category.full_path
            score = path_similarity(full_path, path)
            
            if score > best_score
              best_score = score
              best_match = category
            end
          end
          
          return best_match if best_match
        end
        
        # If we couldn't find a good match or there's only one category, return the first one
        return categories.first
      end
      
      # If we couldn't find by leaf name, try a broader search
      EbayCategory.where("name ILIKE ?", "%#{leaf_name}%").first
    rescue => e
      Rails.logger.error "Error in find_ebay_category_by_path: #{e.message}"
      nil
    end
    
    # Helper method to calculate similarity between two category paths
    def path_similarity(path1, path2)
      # Convert paths to arrays of parts
      parts1 = path1.downcase.split('>').map(&:strip)
      parts2 = path2.downcase.split('>').map(&:strip)
      
      # Count matching parts
      matches = 0
      parts1.each_with_index do |part, i|
        if i < parts2.length && parts2[i].include?(part)
          matches += 1
        end
      end
      
      # Return similarity score (0 to 1)
      matches.to_f / [parts1.length, parts2.length].max
    end
  end
end
