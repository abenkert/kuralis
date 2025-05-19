class JobRun < ApplicationRecord
  belongs_to :shop, optional: true

  scope :recent, -> { order(created_at: :desc) }
  scope :failed, -> { where(status: "failed") }
  scope :completed, -> { where(status: "completed") }
  scope :running, -> { where(status: "running") }
  scope :queued, -> { where(status: "queued") }

  # For Shopify bulk import progress tracking
  def shopify_bulk_progress
    return nil unless job_class == "Shopify::BatchCreateListingsJob"
    Shopify::BulkImportTracker.for_job(self)
  end

  # Method to check if this is a Shopify batch job
  def shopify_batch_job?
    job_class == "Shopify::BatchCreateListingsJob"
  end

  def duration
    return unless completed_at && started_at
    completed_at - started_at
  end

  def queue_time
    return unless started_at && created_at
    started_at - created_at
  end
end
