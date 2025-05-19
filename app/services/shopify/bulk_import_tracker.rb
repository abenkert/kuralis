module Shopify
  class BulkImportTracker
    REDIS_KEY_PREFIX = "shopify_bulk_import"

    def self.current_job_run_id
      Rails.cache.read("#{REDIS_KEY_PREFIX}:current_job_run_id")
    end

    def self.job_progress(job_run_id = nil)
      job_run_id ||= current_job_run_id
      return nil unless job_run_id

      total_batches = Rails.cache.read("#{REDIS_KEY_PREFIX}:#{job_run_id}:total_batches").to_i
      completed_batches = Rails.cache.read("#{REDIS_KEY_PREFIX}:#{job_run_id}:completed_batches").to_i
      total_products = Rails.cache.read("#{REDIS_KEY_PREFIX}:#{job_run_id}:total_products").to_i
      successful_products = Rails.cache.read("#{REDIS_KEY_PREFIX}:#{job_run_id}:successful_products").to_i
      failed_products = Rails.cache.read("#{REDIS_KEY_PREFIX}:#{job_run_id}:failed_products").to_i

      {
        job_run_id: job_run_id,
        total_batches: total_batches,
        completed_batches: completed_batches,
        percent_complete: total_batches > 0 ? (completed_batches.to_f / total_batches * 100).round(1) : 0,
        total_products: total_products,
        successful_products: successful_products,
        failed_products: failed_products,
        in_progress: completed_batches < total_batches
      }
    end

    def self.for_job(job)
      # Check if this is a BatchCreateListingsJob
      return nil unless job.is_a?(Shopify::BatchCreateListingsJob) ||
                        (job.respond_to?(:job_class) && job.job_class == "Shopify::BatchCreateListingsJob")

      # Extract the job run ID from the job's arguments or look up the current one
      args = job.respond_to?(:arguments) ? job.arguments : {}
      batch_index = args[:batch_index] || 0
      total_batches = args[:total_batches] || 0

      # Get overall progress
      progress = job_progress
      return nil unless progress

      # Add job-specific information
      progress.merge({
        batch_index: batch_index,
        batch_number: batch_index + 1,
        is_current_batch: progress[:completed_batches] == batch_index
      })
    end
  end
end
