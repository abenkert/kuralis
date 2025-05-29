class PurgeUnattachedBlobsJob < ApplicationJob
  queue_as :default

  def perform
    # Clean up blobs that were uploaded but never attached to a record
    # This happens with direct uploads when users upload files but don't submit the form

    Rails.logger.info "Starting cleanup of unattached blobs"

    unattached_blobs = ActiveStorage::Blob
      .unattached
      .where(created_at: ..1.day.ago) # Only purge blobs older than 1 day

    count = unattached_blobs.count

    if count > 0
      Rails.logger.info "Found #{count} unattached blobs to purge"
      unattached_blobs.find_each(&:purge_later)
      Rails.logger.info "Queued #{count} blobs for purging"
    else
      Rails.logger.info "No unattached blobs found to purge"
    end
  end
end
