class AiProductAnalysis < ApplicationRecord
  belongs_to :shop
  has_one_attached :image_attachment
  has_one :kuralis_product, dependent: :nullify

  # Validations
  validates :image, presence: true
  validates :status, presence: true, inclusion: { in: %w[pending processing completed failed] }

  # Scopes
  scope :pending, -> { where(status: "pending") }
  scope :processing, -> { where(status: "processing") }
  scope :completed, -> { where(status: "completed") }
  scope :failed, -> { where(status: "failed") }
  scope :unprocessed, -> { where(processed: false) }
  scope :processed, -> { where(processed: true) }
  scope :recent, -> { order(created_at: :desc) }
  scope :ready_for_products, -> { completed.unprocessed }
  scope :with_draft_product, -> { joins(:kuralis_product).where(kuralis_products: { is_draft: true }) }
  scope :without_draft_product, -> {
    left_joins(:kuralis_product)
      .where("kuralis_products.id IS NULL OR kuralis_products.is_draft = ?", false)
  }
  scope :high_confidence, -> { completed.where("results->>'ebay_category_confidence' > '0.8'") }
  scope :low_confidence, -> { completed.where("results->>'ebay_category_confidence' < '0.5'") }
  scope :needs_review, -> { completed.where("results->>'requires_category_review' = 'true' OR results->>'requires_specifics_review' = 'true'") }

  # Virtual attribute for error message
  attr_accessor :error_message

  # Methods
  def pending?
    status == "pending"
  end

  def processing?
    status == "processing"
  end

  def completed?
    status == "completed"
  end

  def failed?
    status == "failed"
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
    update!(status: "processing")
  end

  def mark_as_completed!(results_data)
    update!(
      status: "completed",
      results: results_data,
      processed: false
    )
  end

  def mark_as_failed!(error_message)
    update!(
      status: "failed",
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
    when "pending"
      "Waiting to be analyzed..."
    when "processing"
      "AI is analyzing this image..."
    when "completed"
      "Analysis complete"
    when "failed"
      error_message || "Analysis failed"
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
    results&.dig("title")
  end

  def suggested_description
    results&.dig("description")
  end

  def suggested_brand
    results&.dig("brand")
  end

  def suggested_condition
    results&.dig("condition")
  end

  def suggested_category
    results&.dig("category")
  end

  def suggested_ebay_category
    results&.dig("ebay_category")
  end

  def suggested_item_specifics
    results&.dig("item_specifics") || {}
  end

  def suggested_publisher
    results&.dig("publisher")
  end

  def suggested_year
    results&.dig("year")
  end

  def suggested_issue_number
    results&.dig("issue_number")
  end

  def suggested_tags
    results&.dig("tags") || []
  end

  def suggested_category_confidence
    # Try new confidence_notes format first, fallback to old format
    results&.dig("confidence_notes", "category_confidence") || results&.dig("ebay_category_confidence") || 0.0
  end

  def suggested_item_specifics_confidence
    # Try new confidence_notes format first, fallback to old format
    results&.dig("confidence_notes", "specifics_confidence") || results&.dig("item_specifics_confidence") || 0.0
  end

  def suggested_title_confidence
    results&.dig("confidence_notes", "title_confidence") || 0.0
  end

  def suggested_brand_confidence
    results&.dig("confidence_notes", "brand_confidence") || 0.0
  end

  def confidence_notes
    results&.dig("confidence_notes") || {}
  end

  def overall_confidence_level
    # Calculate overall confidence based on all available confidence scores
    confidences = confidence_notes.values.compact
    return "unknown" if confidences.empty?

    avg_confidence = confidences.sum / confidences.length
    case avg_confidence
    when 0.8..1.0
      "high"
    when 0.6..0.8
      "medium"
    else
      "low"
    end
  end

  def missing_required_specifics
    results&.dig("missing_required_specifics") || []
  end

  def requires_category_review?
    results&.dig("requires_category_review") == true
  end

  def requires_specifics_review?
    results&.dig("requires_specifics_review") == true
  end

  def category_confidence_level
    confidence = suggested_category_confidence
    case confidence
    when 0.8..1.0
      "high"
    when 0.5..0.8
      "medium"
    else
      "low"
    end
  end

  def item_specifics_confidence_level
    confidence = suggested_item_specifics_confidence
    case confidence
    when 0.8..1.0
      "high"
    when 0.5..0.8
      "medium"
    else
      "low"
    end
  end

  # Get error message from results if present
  def error_message
    @error_message || results&.dig("error")
  end

  # Create a draft product from this analysis
  def create_draft_product_from_analysis
    # Check if a draft product already exists for this analysis
    existing_draft = KuralisProduct.find_by(ai_product_analysis_id: id, is_draft: true)
    if existing_draft.present?
      Rails.logger.info "Draft product already exists for analysis #{id}"
      return existing_draft
    end

    # Create the draft product using the existing method
    draft_product = KuralisProduct.create_from_ai_analysis(self, shop)

    if draft_product.persisted?
      Rails.logger.info "Successfully created draft product #{draft_product.id} from analysis #{id}"
    else
      Rails.logger.error "Failed to create draft product from analysis #{id}: #{draft_product.errors.full_messages.join(', ')}"
    end

    draft_product
  rescue => e
    Rails.logger.error "Error creating draft product from analysis #{id}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    nil
  end
end
