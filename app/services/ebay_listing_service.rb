class EbayListingService
  attr_reader :product, :shop

  def initialize(kuralis_product)
    @product = kuralis_product
    @shop = @product.shop
    @ebay_attributes = @product.ebay_product_attribute
  end

  def create_listing
    # Skip if already has eBay listing
    return false if @product.ebay_listing.present?

    # Ensure required eBay attributes are present
    unless @product.has_ebay_attributes?
      raise StandardError, "Product is missing required eBay attributes"
    end

    # Initialize eBay API connection using shop credentials
    api_connection = initialize_ebay_api

    # Build the eBay listing request payload
    listing_request = build_listing_request

    # Make API call to create listing
    response = api_connection.create_listing(listing_request)

    if response && response["listingId"].present?
      # Extract the eBay listing ID from the response
      ebay_listing_id = response["listingId"]

      # Create eBay listing record and associate with product
      ebay_listing = @shop.ebay_listings.create!(
        ebay_id: ebay_listing_id,
        title: @product.title,
        description: @product.description,
        price: @product.base_price,
        quantity: @product.base_quantity,
        status: "active",
        metadata: response
      )

      # Update the Kuralis product with the eBay listing
      @product.update!(
        ebay_listing: ebay_listing,
        last_synced_at: Time.current
      )

      true
    else
      Rails.logger.error "Error creating eBay listing: No listing ID in response"
      false
    end
  rescue => e
    Rails.logger.error "Error creating eBay listing: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    false
  end

  private

  def initialize_ebay_api
    EbayTrading::Api.new(
      auth_token: @shop.ebay_auth_token,
      site_id: @shop.ebay_site_id
    )
  end

  def build_listing_request
    {
      Item: {
        Title: @product.title,
        Description: format_description(@product.description),
        PrimaryCategory: {
          CategoryID: @ebay_attributes.category_id
        },
        StartPrice: @product.base_price,
        ConditionID: @ebay_attributes.condition_id,
        ConditionDescription: @ebay_attributes.condition_description,
        Country: "US", # This should come from shop settings
        Currency: "USD", # This should come from shop settings
        DispatchTimeMax: 3,
        ListingDuration: @ebay_attributes.listing_duration || "GTC",
        ListingType: "FixedPriceItem",
        Quantity: @product.base_quantity,
        ReturnPolicy: {
          ReturnsAcceptedOption: "ReturnsAccepted",
          RefundOption: "MoneyBack",
          ReturnsWithinOption: "Days_30",
          ShippingCostPaidByOption: "Buyer"
        },
        ItemSpecifics: format_item_specifics(@ebay_attributes.item_specifics),
        PictureDetails: format_picture_details
      }
    }
  end

  def format_description(description)
    # Format the description with proper HTML if needed
    "<![CDATA[#{description}]]>"
  end

  def format_item_specifics(specifics)
    return {} unless specifics.present?

    { NameValueList: specifics.map do |name, value|
        { Name: name, Value: value }
      end
    }
  end

  def format_picture_details
    return {} unless @product.images.attached?

    { PictureURL: @product.images.map { |image| generate_image_url(image) } }
  end

  def generate_image_url(image)
    if Rails.env.production?
      Rails.application.routes.url_helpers.url_for(image)
    else
      image.blob.url(expires_in: 1.hour)
    end
  end
end
