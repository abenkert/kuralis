module Kuralis
  class AiProductAnalysesController < AuthenticatedController
    layout "authenticated"

    def index
      @pending_analyses = current_shop.ai_product_analyses.pending&.limit(10)
      @processing_analyses = current_shop.ai_product_analyses.processing&.limit(10)
      @completed_analyses = current_shop.ai_product_analyses.completed.unprocessed&.limit(20)
      @draft_products = current_shop.kuralis_products.draft&.limit(20)
    end

    def show
      analysis = current_shop.ai_product_analyses.find(params[:id])

      render json: analysis.as_json_with_details
    end

    # Create a draft product from an AI Analysis
    def create
      analysis = current_shop.ai_product_analyses.find(params[:analysis_id])

      unless analysis.completed?
        respond_to do |format|
          format.html { redirect_to kuralis_ai_product_analyses_path, alert: "Analysis is not yet complete." }
          format.json { render json: { error: "Analysis not complete" }, status: :unprocessable_entity }
        end
        return
      end

      existing_product = KuralisProduct.find_by(ai_product_analysis_id: analysis.id, is_draft: true)
      if existing_product.present?
        respond_to do |format|
          format.html { redirect_to edit_kuralis_product_path(existing_product, finalize: true), notice: "Editing existing draft product." }
          format.json { render json: { redirect: edit_kuralis_product_path(existing_product, finalize: true) } }
        end
        return
      end

      draft_product = KuralisProduct.create_from_ai_analysis(analysis, current_shop)

      if draft_product.persisted?
        respond_to do |format|
          format.html { redirect_to edit_kuralis_product_path(draft_product, finalize: true), notice: "Draft product created. Please review and finalize it." }
          format.json { render json: { redirect: edit_kuralis_product_path(draft_product, finalize: true) } }
        end
      else
        error_messages = draft_product.errors.full_messages

        if draft_product.ebay_product_attribute&.errors&.any?
          error_messages += draft_product.ebay_product_attribute.errors.full_messages
        end

        respond_to do |format|
          format.html { redirect_to kuralis_ai_product_analyses_path, alert: "Failed to create draft product: #{error_messages.join(', ')}" }
          format.json { render json: { error: error_messages }, status: :unprocessable_entity }
        end
      end
    end

    def upload_images
      Rails.logger.debug "Upload images params: #{params.inspect}"

      # Extract debug info if available
      if params[:debug_info].present?
        begin
          debug_info = JSON.parse(params[:debug_info])
          Rails.logger.debug "Debug info from client: #{debug_info.inspect}"
        rescue => e
          Rails.logger.error "Error parsing debug info: #{e.message}"
        end
      end

      # Check both the regular and fallback inputs
      uploaded_files = []

      # First try the standard 'images' parameter
      if params[:images].present?
        Rails.logger.debug "Found images parameter with type: #{params[:images].class}"

        if params[:images].is_a?(Array)
          Rails.logger.debug "Images is an array with #{params[:images].length} items"
          uploaded_files = params[:images]
        elsif params[:images].is_a?(Hash) || params[:images].is_a?(ActionController::Parameters)
          Rails.logger.debug "Images is a hash/params with #{params[:images].keys.length} keys"
          uploaded_files = params[:images].values
        elsif params[:images].is_a?(ActionDispatch::Http::UploadedFile)
          Rails.logger.debug "Images is a single UploadedFile"
          uploaded_files = [ params[:images] ]
        else
          Rails.logger.debug "Images is some other type (#{params[:images].class}), attempting to process"
          begin
            uploaded_files = Array(params[:images])
          rescue => e
            Rails.logger.error "Failed to convert images to array: #{e.message}"
          end
        end
      else
        Rails.logger.warn "No images found in params"
      end

      Rails.logger.debug "Found #{uploaded_files.length} files to process"

      if uploaded_files.empty?
        redirect_to kuralis_ai_product_analyses_path, alert: "Please select at least one image to upload."
        return
      end

      successful_uploads = 0
      failed_uploads = 0

      uploaded_files.each_with_index do |uploaded_file, index|
        begin
          unless uploaded_file.respond_to?(:original_filename) && uploaded_file.respond_to?(:read)
            Rails.logger.warn "Item #{index} is not a valid file object: #{uploaded_file.class}"
            next
          end

          Rails.logger.debug "Processing file #{index}: #{uploaded_file.original_filename} (#{uploaded_file.content_type}, #{uploaded_file.size} bytes)"

          analysis = current_shop.ai_product_analyses.new(
            status: "pending",
            image: uploaded_file.original_filename
          )

          analysis.image_attachment.attach(uploaded_file)

          if analysis.save
            Rails.logger.debug "Successfully created analysis record for #{uploaded_file.original_filename}"
            successful_uploads += 1

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

      if successful_uploads > 0
        message = "#{successful_uploads} #{'image'.pluralize(successful_uploads)} uploaded and queued for analysis."
        message += " #{failed_uploads} #{'upload'.pluralize(failed_uploads)} failed." if failed_uploads > 0

        redirect_to kuralis_ai_product_analyses_path, notice: message
      else
        redirect_to kuralis_ai_product_analyses_path, alert: "No images were uploaded. Please try again."
      end
    end

    def remove_image
      analysis = current_shop.ai_product_analyses.find(params[:analysis_id])

      if analysis.destroy
        respond_to do |format|
          format.html { redirect_to kuralis_ai_product_analyses_path, notice: "Image removed successfully." }
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
          format.html { redirect_to kuralis_ai_product_analyses_path, alert: "Failed to remove image." }
          format.json { render json: analysis.errors, status: :unprocessable_entity }
          format.turbo_stream {
            flash.now[:alert] = "Failed to remove image."
            render turbo_stream: turbo_stream.prepend("flash", partial: "shared/flash")
          }
        end
      end
    end
  end
end
