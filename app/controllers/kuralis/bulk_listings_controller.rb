module Kuralis
  class BulkListingsController < AuthenticatedController
    def index
      @platform = params[:platform]
      @platforms_available = %w[shopify ebay]

      # Query products unlisted on the selected platform
      case @platform
      when "shopify"
        @products = current_shop.kuralis_products.where(shopify_product_id: nil)
      when "ebay"
        @products = current_shop.kuralis_products.where(ebay_listing_id: nil)
      when "all"
        # Products unlisted on any platform
        @products = current_shop.kuralis_products.unlinked
      else
        # Default to showing all products
        @products = current_shop.kuralis_products
      end

      @total_count = @products.count
      @products = @products.order(created_at: :desc).page(params[:page]).per(100)

      # Check for active bulk listing process
      @active_job_run = find_active_bulk_listing_job
    end

    def create
      platform = params[:platform] || []

      # Ensure at least one platform is selected
      if platform.empty?
        redirect_to kuralis_products_path, alert: "Please select at least one platform for listing."
        return
      end

      if params[:select_all] == "1"
        # Get all product IDs except deselected ones
        deselected_ids = JSON.parse(params[:deselected_ids] || "[]")

        # Find eligible products for each platform and get the intersection
        product_ids = []

        if platform.include?("shopify")
          shopify_ids = current_shop.kuralis_products.where(shopify_product_id: nil).pluck(:id)
          product_ids = product_ids.empty? ? shopify_ids : product_ids & shopify_ids
        end

        if platform.include?("ebay")
          ebay_ids = current_shop.kuralis_products.where(ebay_listing_id: nil).pluck(:id)
          product_ids = product_ids.empty? ? ebay_ids : product_ids & ebay_ids
        end

        # Remove deselected products
        product_ids = product_ids - deselected_ids
      else
        product_ids = params[:product_ids] || []
      end

      if product_ids.empty?
        redirect_to kuralis_products_path, alert: "No eligible products selected for listing."
        return
      end

      # Calculate estimated processing time based on batch size
      batch_count = (product_ids.size.to_f / BulkListingJob::BATCH_SIZE).ceil
      time_estimate = batch_count > 1 ? "#{batch_count} batches" : "1 batch"

      job = BulkListingJob.perform_later(
        shop_id: current_shop.id,
        product_ids: product_ids,
        platforms: platform
      )

      redirect_to kuralis_products_path,
                  notice: "Bulk listing process started for #{product_ids.count} products (#{time_estimate}) on #{platform}. You can monitor progress in the jobs dashboard."
    end

    def progress
      job_id = params[:job_id]

      if job_id.present?
        job_run = JobRun.find_by(job_id: job_id)

        if job_run
          render json: format_job_run_for_progress(job_run)
        else
          render json: { status: "not_found" }
        end
      else
        # Look for the most recent active job
        job_run = find_active_bulk_listing_job

        if job_run
          render json: format_job_run_for_progress(job_run)
        else
          render json: { status: "not_found" }
        end
      end
    end

    private

    def find_active_bulk_listing_job
      # Find the most recent running BulkListingJob
      JobRun.where(
        job_class: "BulkListingJob",
        status: "running",
        shop_id: current_shop.id
      ).order(created_at: :desc).first
    end

    def format_job_run_for_progress(job_run)
      # Extract data from the job_run
      arguments = job_run.arguments || {}

      # Get job metadata
      shop_id = arguments["shop_id"]
      product_ids = arguments["product_ids"] || []
      platform = arguments["platform"] || []
      batch_index = arguments["batch_index"] || 0
      total_batches = arguments["total_batches"] || 1

      # Calculate estimated progress
      estimated_percent_complete = 0
      if batch_index > 0 && total_batches > 0
        estimated_percent_complete = ((batch_index.to_f / total_batches) * 100).round
      end

      # Build the response
      {
        id: job_run.job_id,
        status: job_run.status,
        started_at: job_run.started_at || job_run.created_at,
        shop_id: shop_id,
        platform: platform,
        total_batches: total_batches,
        batch_index: batch_index,
        product_count: product_ids.is_a?(Array) ? product_ids.size : 0,
        estimated_percent_complete: estimated_percent_complete
      }
    end
  end
end
