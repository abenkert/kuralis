class AiProductAnalysis < ApplicationRecord
  belongs_to :shop
  has_one_attached :image_attachment
  has_one :kuralis_product, dependent: :nullify
  
  # Validations
  validates :image, presence: true
  validates :status, presence: true, inclusion: { in: %w[pending processing completed failed] }
  
  # Scopes
  scope :pending, -> { where(status: 'pending') }
  scope :processing, -> { where(status: 'processing') }
  scope :completed, -> { where(status: 'completed') }
  scope :failed, -> { where(status: 'failed') }
  scope :unprocessed, -> { where(processed: false) }
  scope :processed, -> { where(processed: true) }
  scope :recent, -> { order(created_at: :desc) }
  scope :ready_for_products, -> { completed.unprocessed }
  scope :with_draft_product, -> { joins(:kuralis_product).where(kuralis_products: { is_draft: true }) }
  scope :without_draft_product, -> { 
    left_joins(:kuralis_product)
      .where("kuralis_products.id IS NULL OR kuralis_products.is_draft = ?", false)
  }
  
  # Virtual attribute for error message
  attr_accessor :error_message
  
  # Methods
  def pending?
    status == 'pending'
  end
  
  def processing?
    status == 'processing'
  end
  
  def completed?
    status == 'completed'
  end
  
  def failed?
    status == 'failed'
  end
  
  def has_draft_product?
    # Check if there's an associated kuralis_product that is a draft
    kuralis_product.present? && kuralis_product.draft?
  rescue => e
    # Log any errors and return false
    Rails.logger.error "Error checking for draft product: #{e.message}"
    false
  end
  
  def mark_as_processing!
    update!(status: 'processing')
  end
  
  def mark_as_completed!(results_data)
    update!(
      status: 'completed',
      results: results_data,
      processed: false
    )
  end
  
  def mark_as_failed!(error_message)
    update!(
      status: 'failed',
      results: { error: error_message },
      processed: false
    )
    self.error_message = error_message
  end
  
  def mark_as_processed!
    update!(processed: true)
  end
  
  # Returns a human-readable status message
  def status_message
    case status
    when 'pending'
      'Waiting to be analyzed...'
    when 'processing'
      'AI is analyzing this image...'
    when 'completed'
      'Analysis complete'
    when 'failed'
      error_message || 'Analysis failed'
    else
      status
    end
  end
  
  # Returns a status class for styling
  def status_class
    "status-#{status}"
  end
  
  # Returns a hash representation for API/JSON responses
  def as_json_with_details
    {
      id: id,
      status: status,
      status_message: status_message,
      created_at: created_at,
      updated_at: updated_at,
      completed: completed?,
      processed: processed,
      has_image: image_attachment.attached?,
      image_url: image_attachment.attached? ? Rails.application.routes.url_helpers.rails_blob_url(image_attachment) : nil,
      results: completed? ? results : nil,
      error: error_message
    }
  end
  
  # Extract specific data from results
  def suggested_title
    results&.dig('title')
  end
  
  def suggested_description
    results&.dig('description')
  end
  
  def suggested_brand
    results&.dig('brand')
  end
  
  def suggested_condition
    results&.dig('condition')
  end
  
  def suggested_category
    results&.dig('category')
  end
  
  def suggested_ebay_category
    results&.dig('ebay_category')
  end
  
  def suggested_item_specifics
    results&.dig('item_specifics') || {}
  end
  
  def suggested_price
    results&.dig('price')
  end
  
  def suggested_publisher
    results&.dig('publisher')
  end
  
  def suggested_year
    results&.dig('year')
  end
  
  def suggested_issue_number
    results&.dig('issue_number')
  end
  
  def suggested_tags
    results&.dig('tags') || []
  end
  
  # Get error message from results if present
  def error_message
    @error_message || results&.dig('error')
  end
end
