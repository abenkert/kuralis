module Kuralis
  class AiProductAnalysesController < AuthenticatedController
    layout "authenticated"

    def index
      @pending_analyses = current_shop.ai_product_analyses.pending&.limit(10)
      @processing_analyses = current_shop.ai_product_analyses.processing&.limit(10)
      # Load draft products with their AI analysis for confidence badges
      @draft_products = current_shop.kuralis_products.draft.includes(:ai_product_analysis, images_attachments: :blob).recent&.limit(20)
    end

    def show
      analysis = current_shop.ai_product_analyses.find(params[:id])

      render json: analysis.as_json_with_details
    end

    def create
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
        respond_to do |format|
          format.html { redirect_to kuralis_ai_product_analyses_path, alert: "Please select at least one image to upload." }
          format.json { render json: { error: "No images provided" }, status: :unprocessable_entity }
        end
        return
      end

      # Determine if this is a bulk upload (more than 20 files)
      is_bulk_upload = uploaded_files.length > 20

      successful_uploads = 0
      failed_uploads = 0
      analysis_ids = []

      # Process files in batches for bulk uploads
      if is_bulk_upload
        Rails.logger.info "Processing bulk upload of #{uploaded_files.length} files"

        # Process in batches to avoid overwhelming the system
        uploaded_files.each_slice(20) do |batch|
          batch_results = process_file_batch(batch)
          successful_uploads += batch_results[:successful]
          failed_uploads += batch_results[:failed]
          analysis_ids.concat(batch_results[:analysis_ids])

          # Small delay between batches to prevent overwhelming the job queue
          sleep(0.1) if uploaded_files.length > 100
        end
      else
        # Process normally for smaller uploads
        batch_results = process_file_batch(uploaded_files)
        successful_uploads = batch_results[:successful]
        failed_uploads = batch_results[:failed]
        analysis_ids = batch_results[:analysis_ids]
      end

      # Prepare response message
      if successful_uploads > 0
        message = "#{successful_uploads} #{'image'.pluralize(successful_uploads)} uploaded and queued for analysis."
        message += " #{failed_uploads} #{'upload'.pluralize(failed_uploads)} failed." if failed_uploads > 0

        if is_bulk_upload
          message += " Large uploads are processed in batches - check back in a few minutes for results."
        end

        respond_to do |format|
          format.html { redirect_to kuralis_ai_product_analyses_path, notice: message }
          format.json {
            render json: {
              message: message,
              successful: successful_uploads,
              failed: failed_uploads,
              analysis_ids: analysis_ids,
              is_bulk: is_bulk_upload
            }
          }
        end
      else
        respond_to do |format|
          format.html { redirect_to kuralis_ai_product_analyses_path, alert: "No images were uploaded. Please try again." }
          format.json { render json: { error: "No images were uploaded" }, status: :unprocessable_entity }
        end
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

    private

    def process_file_batch(files)
      successful = 0
      failed = 0
      analysis_ids = []

      files.each_with_index do |uploaded_file, index|
        begin
          unless uploaded_file.respond_to?(:original_filename) && uploaded_file.respond_to?(:read)
            Rails.logger.warn "Item #{index} is not a valid file object: #{uploaded_file.class}"
            failed += 1
            next
          end

          # Validate file size (10MB limit)
          max_size = 10.megabytes
          if uploaded_file.size > max_size
            Rails.logger.warn "File #{uploaded_file.original_filename} is too large: #{uploaded_file.size} bytes"
            failed += 1
            next
          end

          # Validate file type
          unless uploaded_file.content_type&.start_with?("image/")
            Rails.logger.warn "File #{uploaded_file.original_filename} is not an image: #{uploaded_file.content_type}"
            failed += 1
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
            successful += 1
            analysis_ids << analysis.id

            # Queue jobs immediately for faster processing
            # For large batches, add small staggered delays to prevent overwhelming OpenAI API
            if files.length > 50
              # Stagger by 2 seconds per job to respect rate limits
              delay = (index * 2).seconds
              AiProductAnalysisJob.set(wait: delay).perform_later(current_shop.id, analysis.id)
            elsif files.length > 20
              # Stagger by 1 second per job for medium batches
              delay = index.seconds
              AiProductAnalysisJob.set(wait: delay).perform_later(current_shop.id, analysis.id)
            else
              # Process immediately for small batches
              AiProductAnalysisJob.perform_later(current_shop.id, analysis.id)
            end
          else
            Rails.logger.error "Failed to save analysis: #{analysis.errors.full_messages.join(', ')}"
            failed += 1
          end
        rescue => e
          Rails.logger.error "Error processing file #{index}: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          failed += 1
        end
      end

      { successful: successful, failed: failed, analysis_ids: analysis_ids }
    end
  end
end
