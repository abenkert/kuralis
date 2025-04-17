class Notification < ApplicationRecord
  belongs_to :shop
  
  # Valid status values
  STATUSES = %w[info success warning error].freeze
  
  validates :title, presence: true
  validates :message, presence: true
  validates :category, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }

  # Scopes
  scope :unread, -> { where(read: false) }
  scope :by_category, ->(category) { where(category: category) }
  scope :by_status, ->(status) { where(status: status) }
  scope :info, -> { where(status: 'info') }
  scope :success, -> { where(status: 'success') }
  scope :warning, -> { where(status: 'warning') }
  scope :error, -> { where(status: 'error') }
  
  # Helper methods
  def info?
    status == 'info'
  end
  
  def success?
    status == 'success'
  end
  
  def warning?
    status == 'warning'
  end
  
  def error?
    status == 'error'
  end
  
  # Bootstrap alert class helper
  def alert_class
    case status
    when 'success' then 'alert-success'
    when 'warning' then 'alert-warning'
    when 'error' then 'alert-danger'
    else 'alert-info'
    end
  end
  
  # Icon helper
  def icon_class
    case status
    when 'success' then 'bi-check-circle'
    when 'warning' then 'bi-exclamation-triangle'
    when 'error' then 'bi-x-circle'
    else 'bi-info-circle'
    end
  end
end 