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
  validates :description, presence: true
  validates :base_price, numericality: { greater_than: 0 }, presence: true
  validates :base_quantity, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, presence: true
  # validates :weight_oz, numericality: { greater_than: 0 }, presence: true
  validates :status, presence: true

  # Scopes
  scope :active, -> { where(status: "active") }
  scope :draft, -> { where(is_draft: true) }
  scope :finalized, -> { where(is_draft: false) }
  scope :from_ebay, -> { where(source_platform: "ebay") }
  scope :from_shopify, -> { where(source_platform: "shopify") }
  scope :unlinked, -> { where(shopify_product_id: nil, ebay_listing_id: nil) }

  after_update :schedule_inventory_sync, if: -> { saved_change_to_base_quantity? && !@skip_inventory_sync }
  # after_update :schedule_general_updates, if: :should_update_platforms?

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

  def inventory_sync?
    self.shop.inventory_sync?
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

  # Validate eBay attributes before listing
  def validate_for_ebay_listing
    errors = []

    unless has_ebay_attributes?
      errors << "eBay product attributes are missing"
      return errors
    end

    attrs = ebay_product_attribute

    errors << "eBay category is required" if attrs.category_id.blank?
    errors << "eBay condition is required" if attrs.condition_id.blank?
    errors << "Listing duration is required" if attrs.listing_duration.blank?

    # For payment, shipping, and return policies, check both the attribute and the default setting
    shop = self.shop

    # Check shipping policy
    if attrs.shipping_profile_id.blank?
      default_shipping = shop.get_setting(KuralisShopSetting::CATEGORIES[:ebay], "default_shipping_policy")
      errors << "Shipping policy is required" if default_shipping.blank?
    end

    # Check payment policy
    if attrs.payment_profile_id.blank?
      default_payment = shop.get_setting(KuralisShopSetting::CATEGORIES[:ebay], "default_payment_policy")
      errors << "Payment policy is required" if default_payment.blank?
    end

    # Check return policy
    if attrs.return_profile_id.blank?
      default_return = shop.get_setting(KuralisShopSetting::CATEGORIES[:ebay], "default_return_policy")
      errors << "Return policy is required" if default_return.blank?
    end

    # Check for attached images
    errors << "At least one product image is required" unless images.attached?

    errors
  end

  # Check if product can be listed on eBay
  def can_list_on_ebay?
    validate_for_ebay_listing.empty?
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
      source_platform: "ai",
      is_draft: true,
      ai_product_analysis_id: analysis.id
    )

    # Attach the image from the analysis
    if analysis.image_attachment.attached?
      draft_product.images.attach(analysis.image_attachment.blob)
    end

    # Save the draft product first - without validating ebay_product_attributes
    if draft_product.save
      p "Draft product saved"
      # Now that the product is saved with an ID, create eBay product attributes if available
      if analysis.suggested_ebay_category.present?
        p "Creating eBay product attribute"
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

  def web_optimized_image_url(image)
    variant = image.variant(
      resize_to_limit: [ 1200, 1200 ],
      format: :webp,
      saver: { quality: 80, strip: true }
    ).processed

    Rails.application.routes.url_helpers.url_for(variant)
  end

  def ebay_optimized_image_url(image)
    variant = image.variant(
      resize_to_limit: [ 1600, 1600 ],
      format: :jpg,
      saver: { quality: 90, strip: true }
    ).processed

    Rails.application.routes.url_helpers.url_for(variant)
  end

  def ebay_compatible_image_urls
    return [] unless images.attached?

    images.map do |image|
      ebay_optimized_image_url(image)
    end
  end

  private

  def schedule_platform_updates
    # Only update platforms when relevant attributes have changed
    return unless should_update_platforms?

    Rails.logger.info "Scheduling platform updates for #{id}"

    Rails.logger.warn "TODO: Implement platform updates in schedule_platform_updates"
    nil
  end

  def schedule_inventory_sync
    # Only schedule inventory sync if inventory_sync is enabled
    return unless inventory_sync?

    Rails.logger.info "Inventory change detected for product_id=#{id}"

    # Record the timestamp of this inventory update
    self.update_column(:last_inventory_update, Time.current)

    # Schedule the new cross-platform sync job (no skip platform)
    CrossPlatformInventorySyncJob.set(wait: 5.seconds).perform_later(shop.id, id, nil)
  end

  # TODO: We need to possibly look at changes to ebay_product_attribute and shopify_product_attributes
  def should_update_platforms?
    # Attributes that should trigger platform updates when changed
    relevant_attributes = [
      :base_price,
      :title,
      :description,
      :status
    ]

    # Check if any relevant attributes have changed
    relevant_attributes.any? { |attr| saved_change_to_attribute?(attr.to_s) }
  end

  def ensure_warehouse
    self.warehouse ||= shop.warehouses.find_by(is_default: true)
  end

  def images_changed?
    saved_changes.key?("id") || # new record
    images.any? { |image| image.blob.created_at > 1.minute.ago } # recently attached images
  end
end
