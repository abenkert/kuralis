class KuralisProduct < ApplicationRecord
  belongs_to :shop
  belongs_to :shopify_product, optional: true
  belongs_to :ebay_listing, optional: true
  has_many_attached :images

  validates :title, presence: true
  validates :base_price, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :base_quantity, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :status, presence: true

  # Scopes
  scope :active, -> { where(status: 'active') }
  scope :from_ebay, -> { where(source_platform: 'ebay') }
  scope :from_shopify, -> { where(source_platform: 'shopify') }
  scope :unlinked, -> { where(shopify_product_id: nil, ebay_listing_id: nil) }
  after_update :schedule_platform_updates, if: :saved_change_to_base_quantity?

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