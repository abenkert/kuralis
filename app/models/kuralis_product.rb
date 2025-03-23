class KuralisProduct < ApplicationRecord
  belongs_to :shop
  belongs_to :shopify_product, optional: true
  belongs_to :ebay_listing, optional: true
  belongs_to :ai_product_analysis, optional: true
  belongs_to :warehouse, optional: true
  before_save :ensure_warehouse
  has_one :ebay_product_attribute, dependent: :destroy
  has_many :inventory_transactions
  has_many :order_items
  has_many_attached :images

  # Image processing configuration for web display
  has_one_attached :thumbnail do |attachable|
    attachable.variant :thumb, resize_to_limit: [ 100, 100 ], format: :webp, quality: 80
    attachable.variant :medium, resize_to_limit: [ 400, 400 ], format: :webp, quality: 80
    attachable.variant :large, resize_to_limit: [ 800, 800 ], format: :webp, quality: 80
  end

  accepts_nested_attributes_for :ebay_product_attribute, reject_if: :all_blank

  validates :title, presence: true
  validates :base_price, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :base_quantity, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :status, presence: true

  # Scopes
  scope :active, -> { where(status: "active") }
  scope :draft, -> { where(is_draft: true) }
  scope :finalized, -> { where(is_draft: false) }
  scope :from_ebay, -> { where(source_platform: "ebay") }
  scope :from_shopify, -> { where(source_platform: "shopify") }
  scope :unlinked, -> { where(shopify_product_id: nil, ebay_listing_id: nil) }
  after_update :schedule_platform_updates, if: :saved_change_to_base_quantity?
  after_save :process_images, if: :images_changed?

  # Handle tags input
  def tags=(value)
    if value.is_a?(String)
      super(value.split(",").map(&:strip))
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

  # Platform eligibility checks
  def eligible_for_shopify?
    !listed_on_shopify? && title.present? && images.attached?
  end

  def eligible_for_ebay?
    !listed_on_ebay? && has_ebay_attributes? && title.present? && images.attached?
  end

  # Get a list of platforms this product is eligible for
  def eligible_platforms
    platforms = []
    platforms << "shopify" if eligible_for_shopify?
    platforms << "ebay" if eligible_for_ebay?
    platforms
  end

  # Get a list of platforms this product is already listed on
  def listed_platforms
    platforms = []
    platforms << "shopify" if listed_on_shopify?
    platforms << "ebay" if listed_on_ebay?
    platforms
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
      status: "active",
      is_draft: true,
      source_platform: "ai",
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
        # Create eBay product attribute directly
        ebay_attr = EbayProductAttribute.create(
          kuralis_product_id: draft_product.id,
          category_id: analysis.suggested_ebay_category
        )

        # Get all item specifics for the category
        category_specifics = ebay_attr.find_or_initialize_item_specifics(shop)

        # Map AI values to the category specifics
        mapped_specifics = Ai::ItemSpecificsMapper.map_to_ebay_format(
          analysis.suggested_item_specifics,
          category_specifics
        )

        # Create a complete hash of all category specifics, with mapped values or empty strings
        all_specifics = category_specifics.each_with_object({}) do |aspect, hash|
          hash[aspect["name"]] = mapped_specifics[aspect["name"]] || ""
        end

        # Update the eBay attribute with all specifics
        ebay_attr.update(item_specifics: all_specifics)

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

  # Returns a processed image variant that meets eBay's requirements
  def prepare_image_for_ebay(image)
    image.variant(
      resize_to_limit: [ 1600, 1600 ],    # Larger size for eBay
      format: :jpg,                     # JPEG format for compatibility
      saver: {
        strip: true,                    # Remove metadata
        quality: 90                     # Higher quality for eBay requirement
      }
    ).processed
  end

  def ebay_compatible_image_urls
    return [] unless images&.attached?

    images.map do |image|
      if image.blob.metadata["ebay_version_key"]
        # Get the eBay-optimized version
        ebay_blob = ActiveStorage::Blob.find_by(key: image.blob.metadata["ebay_version_key"])
        Rails.application.routes.url_helpers.rails_blob_url(ebay_blob) if ebay_blob
      else
        # If no eBay version exists, create one on the fly
        variant = prepare_image_for_ebay(image)
        Rails.application.routes.url_helpers.url_for(variant)
      end
    end.compact
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

  def ensure_warehouse
    self.warehouse ||= shop.warehouses.find_by(is_default: true)
  end

  def images_changed?
    saved_changes.key?("id") || # new record
    images.any? { |image| image.blob.created_at > 1.minute.ago } # recently attached images
  end

  def process_images
    return unless images.attached?

    images.each do |image|
      next if image.blob.metadata["processed"] # Skip if already processed

      # Create web-optimized version (for our interface)
      web_version = image.variant(
        resize_to_limit: [ 1200, 1200 ],
        format: :webp,
        quality: 80,
        saver: { strip: true }
      ).processed

      # Only update if the processed version is smaller
      if web_version.image.blob.byte_size < image.blob.byte_size
        # Store original image data for potential eBay use
        original_blob = image.blob.dup

        # Update the blob with web-optimized version
        image.blob.update!(
          io: File.open(web_version.image.path),
          filename: "#{image.blob.filename.base}.webp",
          content_type: "image/webp"
        )

        # Create and attach eBay-compatible version if needed
        if eligible_for_ebay? || listed_on_ebay?
          ebay_version = original_blob.variant(
            resize_to_limit: [ 1600, 1600 ],
            format: :jpg,
            quality: 90,
            saver: { strip: true }
          ).processed

          # Store the eBay version with a different key
          key = "ebay_#{SecureRandom.uuid}"
          blob = ActiveStorage::Blob.create_and_upload!(
            io: File.open(ebay_version.image.path),
            filename: "#{image.blob.filename.base}.jpg",
            content_type: "image/jpeg",
            key: key
          )

          # Store the reference to the eBay-compatible image and mark as processed
          image.blob.update(
            metadata: image.blob.metadata.merge(
              ebay_version_key: key,
              processed: true
            )
          )
        end
      end
    end
  end
end
