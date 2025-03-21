class EbayListingService
  attr_reader :product, :shop

  def initialize(kuralis_product)
    @product = kuralis_product
    @shop = @product.shop
    @ebay_attributes = @product.ebay_product_attribute
    @token_service = EbayTokenService.new(@shop)
  end

  def create_listing
    # Skip if already has eBay listing
    return false if @product.ebay_listing.present? && @product.ebay_listing.ebay_status == "active"

    # Ensure required eBay attributes are present
    unless @product.has_ebay_attributes?
      raise StandardError, "Product is missing required eBay attributes"
    end

    # First verify the listing
    verify_result = verify_listing
    unless verify_result[:success]
      Rails.logger.error "Listing verification failed: #{verify_result[:error]}"
      return false
    end

    p verify_result
    # If verification passed, create the actual listing
    # create_fixed_price_item
  end

  private

  def verify_listing
    make_api_call("VerifyAddFixedPriceItem", build_item_request)
  end

  def create_fixed_price_item
    result = make_api_call("AddFixedPriceItem", build_item_request)

    if result[:success]
      doc = result[:response]
      namespace = { "ebay" => "urn:ebay:apis:eBLBaseComponents" }
      ebay_item_id = doc.at_xpath("//ebay:ItemID", namespace)&.text

      # Create eBay listing record and associate with product
      ebay_listing = @shop.ebay_listings.create!(
        ebay_item_id: ebay_item_id,
        title: @product.title,
        description: @product.description,
        sale_price: @product.base_price,
        quantity: @product.base_quantity,
        ebay_status: "active",
        metadata: doc.to_s
      )

      # Update the Kuralis product with the eBay listing
      @product.update!(
        ebay_listing: ebay_listing,
        last_synced_at: Time.current
      )

      true
    else
      false
    end
  end

  def make_api_call(call_name, request_body)
    token = @token_service.fetch_or_refresh_access_token
    uri = URI("https://api.ebay.com/ws/api.dll")

    headers = {
      "X-EBAY-API-COMPATIBILITY-LEVEL" => "967",
      "X-EBAY-API-IAF-TOKEN" => token,
      "X-EBAY-API-DEV-NAME" => ENV["EBAY_DEV_ID"],
      "X-EBAY-API-APP-NAME" => ENV["EBAY_CLIENT_ID"],
      "X-EBAY-API-CERT-NAME" => ENV["EBAY_CLIENT_SECRET"],
      "X-EBAY-API-CALL-NAME" => call_name,
      "X-EBAY-API-SITEID" => "0",
      "Content-Type" => "text/xml"
    }

    begin
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        request = Net::HTTP::Post.new(uri, headers)
        request.body = request_body
        http.request(request)
      end

      if response.is_a?(Net::HTTPSuccess)
        doc = Nokogiri::XML(response.body)
        namespace = { "ebay" => "urn:ebay:apis:eBLBaseComponents" }

        if doc.at_xpath("//ebay:Ack", namespace)&.text == "Success"
          { success: true, response: doc }
        else
          error_message = doc.at_xpath("//ebay:Errors/ebay:ShortMessage", namespace)&.text || "Unknown error"
          Rails.logger.error "eBay API Error (#{call_name}): #{error_message}"
          { success: false, error: error_message }
        end
      else
        Rails.logger.error "HTTP Error in #{call_name}: #{response.code} - #{response.body}"
        { success: false, error: "HTTP Error #{response.code}" }
      end
    rescue => e
      Rails.logger.error "Error in #{call_name}: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      { success: false, error: e.message }
    end
  end

  def build_item_request
    <<~XML
      <?xml version="1.0" encoding="utf-8"?>
      <#{@api_call_name}Request xmlns="urn:ebay:apis:eBLBaseComponents">
        <RequesterCredentials>
          <eBayAuthToken>#{@token_service.fetch_or_refresh_access_token}</eBayAuthToken>
        </RequesterCredentials>
        <Item>
          <Title>#{CGI.escapeHTML(@product.title)}</Title>
          <Description>#{format_description(@product.description)}</Description>
          <PrimaryCategory>
            <CategoryID>#{@ebay_attributes.category_id}</CategoryID>
          </PrimaryCategory>
          <StartPrice>#{@product.base_price}</StartPrice>
          <ConditionID>#{@ebay_attributes.condition_id}</ConditionID>
          <ConditionDescription>#{CGI.escapeHTML(@ebay_attributes.condition_description.to_s)}</ConditionDescription>
          <Country>US</Country>
          <Currency>USD</Currency>
          <Location>US</Location>
          <PostalCode>#{@product.warehouse.postal_code}</PostalCode>
          <ListingDuration>GTC</ListingDuration>
          <ListingType>FixedPriceItem</ListingType>
          <Quantity>#{@product.base_quantity}</Quantity>
          #{build_item_specifics_xml}
          #{build_picture_details_xml}
          <PaymentPolicy>
            <PaymentPolicyID>#{@ebay_attributes.payment_policy_id}</PaymentPolicyID>
          </PaymentPolicy>
          <ReturnPolicy>
            <ReturnPolicyID>#{@ebay_attributes.return_policy_id}</ReturnPolicyID>
          </ReturnPolicy>
          <ShippingDetails>
            <ShippingProfileID>#{@ebay_attributes.shipping_profile_id}</ShippingProfileID>
          </ShippingDetails>
        </Item>
      </#{@api_call_name}Request>
    XML
  end

  def format_description(description)
    "<![CDATA[#{description}]]>"
  end

  def build_item_specifics_xml
    return "" unless @ebay_attributes.item_specifics.present?

    specifics_xml = @ebay_attributes.item_specifics.map do |name, value|
      <<~XML
        <NameValueList>
          <Name>#{CGI.escapeHTML(name)}</Name>
          <Value>#{CGI.escapeHTML(value)}</Value>
        </NameValueList>
      XML
    end.join

    "<ItemSpecifics>#{specifics_xml}</ItemSpecifics>"
  end

  def build_picture_details_xml
    return "" unless @product.images.attached?

    image_upload_service = EbayImageUploadService.new(@shop)
    uploaded_urls = []

    @product.images.each do |image|
      result = image_upload_service.upload_image(image)
      if result[:success]
        uploaded_urls << result[:url]
      else
        Rails.logger.error "Failed to upload image #{image.filename}: #{result[:error]}"
      end
    end

    return "" if uploaded_urls.empty?

    urls_xml = uploaded_urls.map do |url|
      "<PictureURL>#{CGI.escapeHTML(url)}</PictureURL>"
    end.join

    "<PictureDetails>#{urls_xml}</PictureDetails>"
  end
end
