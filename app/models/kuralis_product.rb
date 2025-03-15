class KuralisProduct < ApplicationRecord
  belongs_to :shop
  belongs_to :shopify_product, optional: true
  belongs_to :ebay_listing, optional: true
  belongs_to :ai_product_analysis, optional: true
  has_many_attached :images
  has_one :ebay_product_attribute, dependent: :destroy
  accepts_nested_attributes_for :ebay_product_attribute, reject_if: :all_blank

  validates :title, presence: true
  validates :base_price, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :base_quantity, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :status, presence: true

  # Scopes
  scope :active, -> { where(status: 'active') }
  scope :draft, -> { where(is_draft: true) }
  scope :finalized, -> { where(is_draft: false) }
  scope :from_ebay, -> { where(source_platform: 'ebay') }
  scope :from_shopify, -> { where(source_platform: 'shopify') }
  scope :unlinked, -> { where(shopify_product_id: nil, ebay_listing_id: nil) }
  after_update :schedule_platform_updates, if: :saved_change_to_base_quantity?

  # Handle tags input
  def tags=(value)
    if value.is_a?(String)
      super(value.split(',').map(&:strip))
    else
      super
    end
  end

  def ebay_attributes
    ebay_product_attribute || build_ebay_product_attribute
  end
  
  # Method to check if product has eBay attributes
  def has_ebay_attributes?
    ebay_product_attribute.present?
  end

  # Platform presence checks
  def listed_on_shopify?
    shopify_product.present?
  end

  def listed_on_ebay?
    ebay_listing.present?
  end

  def sync_needed?
    last_synced_at.nil? || last_synced_at < updated_at
  end
  
  # Draft methods
  def draft?
    is_draft
  end
  
  def finalized?
    !is_draft
  end
  
  def finalize!
    update!(is_draft: false)
  end
  
  # Create a draft product from AI analysis
  def self.create_from_ai_analysis(analysis, shop)
    draft_product = shop.kuralis_products.new(
      title: analysis.suggested_title.presence || "Untitled Product",
      description: analysis.suggested_description,
      base_price: analysis.suggested_price,
      base_quantity: 1, # Default to 1 for draft products
      brand: analysis.suggested_brand,
      condition: analysis.suggested_condition,
      tags: analysis.suggested_tags,
      status: 'active',
      is_draft: true,
      source_platform: 'ai',
      ai_product_analysis_id: analysis.id
    )
    
    # Attach the image from the analysis
    if analysis.image_attachment.attached?
      draft_product.images.attach(analysis.image_attachment.blob)
    end
    
    # Save the draft product first - without validating ebay_product_attributes
    if draft_product.save
      # Now that the product is saved with an ID, create eBay product attributes if available
      if analysis.suggested_ebay_category.present?
        # Ensure item_specifics is a hash
        item_specifics = if analysis.suggested_item_specifics.is_a?(Hash)
                          analysis.suggested_item_specifics
                        else
                          {}
                        end
        
        # Create eBay product attribute directly
        ebay_attr = EbayProductAttribute.create(
          kuralis_product_id: draft_product.id,
          category_id: analysis.suggested_ebay_category,
          item_specifics: item_specifics
        )
        
        # If the eBay attribute can't be saved, log the error but continue
        unless ebay_attr.persisted?
          Rails.logger.error "Failed to save eBay attributes: #{ebay_attr.errors.full_messages.join(', ')}"
        end
      end
      
      # Mark the analysis as processed
      analysis.mark_as_processed!
    end
    
    draft_product
  end

  # Add image caching method
  def cache_images
    return if image_urls.blank?

    image_urls.each do |url|
      begin
        images.attach(io: URI.open(url), filename: File.basename(url))
      rescue => e
        Rails.logger.error "Failed to cache image from #{url}: #{e.message}"
      end
    end
    
    update(images_last_synced_at: Time.current)
  end
  
  private
  
  def schedule_platform_updates
    # Queue jobs to update associated platforms
    Rails.logger.info "Scheduling platform updates for #{id}"
    # TODO: Add platform update jobs here
    # TODO: This is where we will schedule the jobs to update the quantity on associated platforms
    # if ebay_listing.present?
    #   Ebay::UpdateListingJob.perform_later(ebay_listing.id)
    #   Rails.logger.info "Scheduled eBay update for listing #{ebay_listing.id} after inventory change"
    # end
    
    # if shopify_product.present?
    #   Shopify::UpdateProductJob.perform_later(shopify_product.id)
    #   Rails.logger.info "Scheduled Shopify update for product #{shopify_product.id} after inventory change"
    # end
  end
end 