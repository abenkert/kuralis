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
      upload_start_time = Time.current
      Rails.logger.debug "Upload images params: #{params.inspect}"

      # Handle both direct uploads (signed_ids) and traditional uploads
      uploaded_files = []
      signed_ids = []

      # Check for direct upload signed IDs (modern approach)
      if params[:images].present? && params[:images].all? { |img| img.is_a?(String) }
        Rails.logger.debug "Processing direct upload signed IDs"
        signed_ids = params[:images]

        # Convert signed IDs to blobs
        uploaded_files = signed_ids.map do |signed_id|
          begin
            ActiveStorage::Blob.find_signed(signed_id)
          rescue => e
            Rails.logger.error "Invalid signed ID #{signed_id}: #{e.message}"
            nil
          end
        end.compact

        Rails.logger.debug "Found #{uploaded_files.length} valid blobs from signed IDs"
      else
        # Traditional file upload handling (fallback)
        Rails.logger.debug "Processing traditional file uploads"

        if params[:images].present?
          if params[:images].is_a?(Array)
            uploaded_files = params[:images]
          elsif params[:images].is_a?(Hash) || params[:images].is_a?(ActionController::Parameters)
            uploaded_files = params[:images].values
          elsif params[:images].is_a?(ActionDispatch::Http::UploadedFile)
            uploaded_files = [ params[:images] ]
          else
            begin
              uploaded_files = Array(params[:images])
            rescue => e
              Rails.logger.error "Failed to convert images to array: #{e.message}"
            end
          end
        end
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
        upload_duration = Time.current - upload_start_time
        Rails.logger.info "Upload completed: #{successful_uploads} files processed in #{upload_duration.round(2)}s (avg: #{(upload_duration / successful_uploads).round(3)}s per file)"

        message = "#{successful_uploads} #{'image'.pluralize(successful_uploads)} uploaded and queued for analysis."
        message += " #{failed_uploads} #{'upload'.pluralize(failed_uploads)} failed." if failed_uploads > 0

        respond_to do |format|
          format.html {
            if is_bulk_upload
              redirect_to kuralis_ai_product_analyses_path(tab: "processing"),
                          notice: message + " Large uploads are processed in batches - check back in a few minutes for results."
            else
              redirect_to kuralis_ai_product_analyses_path(tab: "processing"), notice: message
            end
          }
          format.json {
            render json: {
              success: true,
              message: message,
              successful: successful_uploads,
              failed: failed_uploads,
              analysis_ids: analysis_ids,
              is_bulk: is_bulk_upload,
              upload_duration: upload_duration.round(2),
              redirect_url: kuralis_ai_product_analyses_path(tab: "processing")
            }
          }
        end
      else
        respond_to do |format|
          format.html { redirect_to kuralis_ai_product_analyses_path, alert: "No images were uploaded. Please try again." }
          format.json { render json: { success: false, error: "No images were uploaded" }, status: :unprocessable_entity }
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

      files.each_with_index do |file_or_blob, index|
        begin
          # Handle both ActiveStorage::Blob (direct upload) and UploadedFile (traditional)
          if file_or_blob.is_a?(ActiveStorage::Blob)
            # Direct upload - blob is already stored
            blob = file_or_blob
            filename = blob.filename.to_s
            content_type = blob.content_type
            file_size = blob.byte_size

            Rails.logger.debug "Processing direct upload blob #{index}: #{filename} (#{content_type}, #{file_size} bytes)"
          else
            # Traditional upload - need to validate
            uploaded_file = file_or_blob

            unless uploaded_file.respond_to?(:original_filename) && uploaded_file.respond_to?(:read)
              Rails.logger.warn "Item #{index} is not a valid file object: #{uploaded_file.class}"
              failed += 1
              next
            end

            filename = uploaded_file.original_filename
            content_type = uploaded_file.content_type
            file_size = uploaded_file.size

            Rails.logger.debug "Processing traditional upload #{index}: #{filename} (#{content_type}, #{file_size} bytes)"
          end

          # Validate file size (10MB limit)
          max_size = 10.megabytes
          if file_size > max_size
            Rails.logger.warn "File #{filename} is too large: #{file_size} bytes"
            failed += 1
            next
          end

          # Validate file type
          unless content_type&.start_with?("image/")
            Rails.logger.warn "File #{filename} is not an image: #{content_type}"
            failed += 1
            next
          end

          # Create analysis record
          analysis = current_shop.ai_product_analyses.new(
            status: "pending",
            image: filename
          )

          # Attach the file/blob
          if file_or_blob.is_a?(ActiveStorage::Blob)
            # For direct uploads, attach the existing blob
            analysis.image_attachment.attach(blob)
          else
            # For traditional uploads, attach the uploaded file
            analysis.image_attachment.attach(uploaded_file)
          end

          if analysis.save
            Rails.logger.debug "Successfully created analysis record for #{filename}"
            successful += 1
            analysis_ids << analysis.id

            # Queue jobs with smart delays
            if files.length > 50
              delay = (index * 2).seconds
              AiProductAnalysisJob.set(wait: delay).perform_later(current_shop.id, analysis.id)
            elsif files.length > 20
              delay = index.seconds
              AiProductAnalysisJob.set(wait: delay).perform_later(current_shop.id, analysis.id)
            else
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
