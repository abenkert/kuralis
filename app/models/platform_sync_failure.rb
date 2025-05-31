class PlatformSyncFailure < ApplicationRecord
  belongs_to :kuralis_product
  belongs_to :shop

  validates :failed_platforms, presence: true
  validates :successful_platforms, presence: true
  validates :failure_type, presence: true, inclusion: { in: %w[total_failure partial_failure multiple_failure] }
  validates :status, presence: true, inclusion: { in: %w[pending retrying critical resolved failed] }
  validates :retry_count, numericality: { greater_than_or_equal_to: 0 }

  scope :pending, -> { where(status: "pending") }
  scope :retrying, -> { where(status: "retrying") }
  scope :critical, -> { where(status: "critical") }
  scope :resolved, -> { where(status: "resolved") }
  scope :failed, -> { where(status: "failed") }
  scope :recent, -> { where("created_at > ?", 24.hours.ago) }
  scope :needs_retry, -> { where(status: [ "pending", "retrying" ]).where("retry_count < ?", PlatformSyncRecoveryService::MAX_RETRIES) }

  def can_retry?
    [ "pending", "retrying" ].include?(status) && retry_count < PlatformSyncRecoveryService::MAX_RETRIES
  end

  def critical?
    status == "critical"
  end

  def resolved?
    status == "resolved"
  end

  def abandoned?
    status == "failed"
  end

  def mark_resolved!
    update!(
      status: "resolved",
      resolved_at: Time.current
    )
  end

  def mark_abandoned!
    update!(
      status: "failed",
      abandoned_at: Time.current
    )
  end

  def increment_retry_count!
    update!(retry_count: retry_count + 1)
  end

  def failed_platform_names
    failed_platforms.map(&:titleize).join(", ")
  end

  def successful_platform_names
    successful_platforms.map(&:titleize).join(", ")
  end

  def age_in_hours
    ((Time.current - created_at) / 1.hour).round(1)
  end

  def next_retry_at
    return nil unless can_retry?

    interval = PlatformSyncRecoveryService::RETRY_INTERVALS[retry_count] || PlatformSyncRecoveryService::RETRY_INTERVALS.last
    created_at + (retry_count * interval.seconds)
  end
end
