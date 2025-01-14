class EbayListing < ApplicationRecord
  belongs_to :shopify_ebay_account
  has_one :kuralis_product
  has_many_attached :images
  
  validates :ebay_item_id, presence: true, 
            uniqueness: { scope: :shopify_ebay_account_id }
#   validates :sale_price, numericality: { greater_than_or_equal_to: 0 }, 
#             allow_nil: true
#   validates :original_price, numericality: { greater_than_or_equal_to: 0 }, 
#             allow_nil: true
#   validates :quantity, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  
  # Scopes
  scope :active, -> { where(ebay_status: 'active') }
  scope :ended, -> { where(ebay_status: 'ended') }
  scope :needs_sync, -> { where('last_sync_at < updated_at OR last_sync_at IS NULL') }
  
  # Helper methods
  def active?
    ebay_status == 'active'
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

  def test_image_upload
    begin
      # Test with a small image
      test_url = "https://i.ebayimg.com/00/s/MTYwMFgxMjAw/z/IXMAAOSwKQRkOEOT/$_57.JPG"
      temp_file = Down.download(test_url)
      
      images.attach(
        io: temp_file,
        filename: "test_image.jpg",
        content_type: temp_file.content_type
      )
      
      return {
        success: true,
        url: images.last.url,
        message: "Image uploaded successfully!"
      }
    rescue => e
      return {
        success: false,
        error: e.message
      }
    ensure
      temp_file&.close
      temp_file&.unlink
    end
  end
end 