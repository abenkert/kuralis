# This model represents ACTUAL listings that exist on eBay. It serves as a cached/synced
# copy of listing data from eBay's platform, reducing the need for frequent API calls.
#
# Key characteristics:
# - Must have an ebay_item_id (represents a real eBay listing)
# - Used primarily for imported/existing eBay listings
# - May not always be 100% in sync with eBay (see last_sync_at)
# - Contains live listing data (price, quantity, status)
#
# Relationships:
# - belongs_to :shopify_ebay_account
# - has_one :kuralis_product
#
# Example usage:
# - Importing existing eBay listings
# - Tracking listing status and performance
# - Syncing inventory between platforms
class EbayListing < ApplicationRecord
  belongs_to :shopify_ebay_account
  has_one :kuralis_product, dependent: :nullify
  has_many_attached :images

  validates :ebay_item_id, presence: true,
            uniqueness: { scope: :shopify_ebay_account_id }
  validates :total_quantity, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :quantity_sold, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :quantity, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  # Custom validation to ensure quantity_sold doesn't exceed total_quantity
  validate :quantity_sold_not_greater_than_total

  # Custom validation to ensure available quantity matches calculation
  validate :available_quantity_matches_calculation
  #   validates :sale_price, numericality: { greater_than_or_equal_to: 0 },
  #             allow_nil: true
  #   validates :original_price, numericality: { greater_than_or_equal_to: 0 },
  #             allow_nil: true
  #   validates :quantity, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  # Scopes
  scope :active, -> { where(ebay_status: "active") }
  scope :completed, -> { where(ebay_status: "completed") }
  scope :needs_sync, -> { where("last_sync_at < updated_at OR last_sync_at IS NULL") }

  # Helper methods
  def active?
    ebay_status == "active"
  end

  def on_sale?
    original_price.present? && sale_price < original_price
  end

  def discount_percentage
    return nil unless on_sale?
    ((original_price - sale_price) / original_price * 100).round(2)
  end

  def primary_image_url
    image_urls.first if image_urls.present?
  end

  def sync_needed?
    last_sync_at.nil? || last_sync_at < updated_at
  end

  def self.create_from_product(product, ebay_item_id)
    return nil unless product.ebay_product_attribute

    # Get the configuration from ebay_product_attribute
    config = product.ebay_product_attribute

    # Create new listing with transferred data
    listing = new(
      shopify_ebay_account: product.shop.shopify_ebay_account,
      ebay_item_id: ebay_item_id,
      title: product.title,
      description: product.description,
      sale_price: product.base_price,
      quantity: product.base_quantity,
      listing_format: "FixedPriceItem",
      category_id: config.category_id || 0,
      condition_id: config.condition_id || 0,
      condition_description: config.condition_description || "",
      store_category_id: config.store_category_id || 0,
      listing_duration: config.listing_duration || "GTC",
      best_offer_enabled: config.best_offer_enabled || true,
      shipping_profile_id: config.shipping_profile_id,
      payment_profile_id: config.payment_profile_id,
      return_profile_id: config.return_profile_id,
      item_specifics: config.item_specifics || {},
      location: product.location,
      image_urls: product.image_urls,
      ebay_status: "active",
      end_time: 1.month.from_now, # This needs to be calculated if not set GTC
    )

    # Associate the listing with the product if saved successfully
    if listing.save
      product.update(ebay_listing: listing)

      # Attach product images to the ebay_listing
      if product.images.attached?
        product.images.each do |image|
          listing.images.attach(
            io: StringIO.new(image.download),
            filename: image.filename.to_s,
            content_type: image.content_type
          )
        end
      end
    end

    listing
  end

  def cache_images
    return if images.attached?

    image_urls.each_with_index do |url, index|
      begin
        temp_file = Down.download(url)
        images.attach(
          io: temp_file,
          filename: "ebay_image_#{index}.jpg",
          content_type: temp_file.content_type
        )
      rescue => e
        Rails.logger.error "Failed to cache image from #{url}: #{e.message}"
      ensure
        temp_file&.close
        temp_file&.unlink
      end
    end
  end

  def store_category_name
    shopify_ebay_account.store_category_name(store_category_id)
  end

  # Returns URLs of images in eBay-compatible format for listing creation/update
  def ebay_compatible_image_urls
    return [] unless kuralis_product&.images&.attached?

    kuralis_product.images.map do |image|
      if image.blob.metadata["ebay_version_key"]
        # Get the eBay-optimized version
        ebay_blob = ActiveStorage::Blob.find_by(key: image.blob.metadata["ebay_version_key"])
        Rails.application.routes.url_helpers.rails_blob_url(ebay_blob) if ebay_blob
      else
        # If no eBay version exists, create one on the fly
        variant = kuralis_product.prepare_image_for_ebay(image)
        Rails.application.routes.url_helpers.url_for(variant)
      end
    end.compact
  end

  # Returns URLs of images as they appear on eBay
  def ebay_hosted_image_urls
    image_urls
  end

  # Upgrades eBay image URLs to high-quality variants
  def upgrade_image_urls_to_high_quality!
    return if image_urls.blank?

    high_quality_urls = image_urls.map do |url|
      if url.match?(/\/\$_\d+\.JPG\?/)
        # Replace the "$_X" part with "$_57" to get the high quality variant
        high_quality_url = url.gsub(/\/\$_\d+\.JPG\?/, "/$_57.JPG?")
        # Also update the set_id parameter for higher quality if present
        high_quality_url = high_quality_url.gsub(/set_id=\d+/, "set_id=880000500F") if high_quality_url.include?("set_id=")
        high_quality_url
      else
        url
      end
    end

    if high_quality_urls != image_urls
      update(image_urls: high_quality_urls)
      Rails.logger.info "Upgraded image URLs to high-quality variants for eBay listing #{ebay_item_id}"
    end

    high_quality_urls
  end

  # Custom validation to ensure quantity_sold doesn't exceed total_quantity
  def quantity_sold_not_greater_than_total
    if quantity_sold > total_quantity
      errors.add(:quantity_sold, "cannot exceed total_quantity")
    end
  end

  # Custom validation to ensure available quantity matches calculation
  def available_quantity_matches_calculation
    if quantity != total_quantity - quantity_sold
      errors.add(:quantity, "must match the calculation of total_quantity minus quantity_sold")
    end
  end

  # Quantity tracking helper methods
  def available_quantity
    quantity
  end

  def sold_percentage
    return 0 if total_quantity.zero?
    (quantity_sold.to_f / total_quantity * 100).round(2)
  end

  def has_sales?
    quantity_sold > 0
  end

  def out_of_stock?
    quantity.zero?
  end

  def low_stock?(threshold = 5)
    quantity <= threshold && quantity > 0
  end

  def quantity_status
    if out_of_stock?
      "Out of Stock"
    elsif low_stock?
      "Low Stock"
    else
      "In Stock"
    end
  end
end
