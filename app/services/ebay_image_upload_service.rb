class EbayImageUploadService
  def initialize(shop)
    @shop = shop
    @token_service = EbayTokenService.new(@shop)
  end

  def upload_image(image_file)
    token = @token_service.fetch_or_refresh_access_token
    uri = URI("https://api.ebay.com/ws/api.dll")

    # Process the image
    begin
      image_content = process_image(image_file)
    rescue => e
      Rails.logger.error "Error processing image: #{e.message}"
      return { success: false, error: "Image processing failed: #{e.message}" }
    end

    # Generate a unique boundary for multipart
    boundary = "EbayImageUpload#{SecureRandom.hex(10)}"

    headers = {
      "X-EBAY-API-COMPATIBILITY-LEVEL" => "967",
      "X-EBAY-API-IAF-TOKEN" => token,
      "X-EBAY-API-DEV-NAME" => ENV["EBAY_DEV_ID"],
      "X-EBAY-API-APP-NAME" => ENV["EBAY_CLIENT_ID"],
      "X-EBAY-API-CERT-NAME" => ENV["EBAY_CLIENT_SECRET"],
      "X-EBAY-API-CALL-NAME" => "UploadSiteHostedPictures",
      "X-EBAY-API-SITEID" => "0",
      "Content-Type" => "multipart/form-data; boundary=#{boundary}"
    }

    # Create the XML part without the image data
    xml_request = <<~XML
      <?xml version="1.0" encoding="utf-8"?>
      <UploadSiteHostedPicturesRequest xmlns="urn:ebay:apis:eBLBaseComponents">
        <RequesterCredentials>
          <eBayAuthToken>#{token}</eBayAuthToken>
        </RequesterCredentials>
        <PictureName>#{CGI.escapeHTML(image_file.filename.to_s)}</PictureName>
      </UploadSiteHostedPicturesRequest>
    XML

    # Build multipart body
    post_body = []

    # Add XML part
    post_body << "--#{boundary}"
    post_body << "Content-Disposition: form-data; name=\"XML Payload\""
    post_body << "Content-Type: text/xml;charset=utf-8"
    post_body << ""
    post_body << xml_request

    # Add image part
    post_body << "--#{boundary}"
    post_body << "Content-Disposition: form-data; name=\"Image\"; filename=\"#{image_file.filename}\""
    post_body << "Content-Type: #{image_file.content_type}"
    post_body << "Content-Transfer-Encoding: binary"
    post_body << ""
    post_body << image_content

    # Add final boundary
    post_body << "--#{boundary}--"

    begin
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        request = Net::HTTP::Post.new(uri, headers)
        request.body = post_body.join("\r\n")
        http.request(request)
      end

      if response.is_a?(Net::HTTPSuccess)
        doc = Nokogiri::XML(response.body)
        namespace = { "ebay" => "urn:ebay:apis:eBLBaseComponents" }

        if doc.at_xpath("//ebay:Ack", namespace)&.text == "Success"
          url = doc.at_xpath("//ebay:SiteHostedPictureDetails/ebay:FullURL", namespace)&.text
          { success: true, url: url }
        else
          error_message = doc.at_xpath("//ebay:Errors/ebay:ShortMessage", namespace)&.text || "Unknown error"
          long_message = doc.at_xpath("//ebay:Errors/ebay:LongMessage", namespace)&.text
          error_code = doc.at_xpath("//ebay:Errors/ebay:ErrorCode", namespace)&.text

          Rails.logger.error "eBay Image Upload Error: #{error_message}"
          Rails.logger.error "Details: #{long_message} (Code: #{error_code})"
          { success: false, error: error_message, details: long_message, code: error_code }
        end
      else
        Rails.logger.error "HTTP Error in image upload: #{response.code} - #{response.body}"
        { success: false, error: "HTTP Error #{response.code}" }
      end
    rescue => e
      Rails.logger.error "Error uploading image: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      { success: false, error: e.message }
    end
  end

  private

  def process_image(image_file)
    require "mini_magick"

    # Create a temporary file to process the image
    temp_file = Tempfile.new([ "ebay_image", File.extname(image_file.filename.to_s) ])
    begin
      # Download the Active Storage blob to the temp file
      temp_file.binmode
      temp_file.write(image_file.download)
      temp_file.rewind

      # Process the image with MiniMagick
      image = MiniMagick::Image.new(temp_file.path)

      # Ensure the image is in a web-friendly format
      image.format "JPEG" unless [ "JPEG", "JPG", "PNG" ].include?(image.type)

      # Resize if too large (eBay has maximum dimensions)
      max_dimension = 1600
      if image.width > max_dimension || image.height > max_dimension
        image.resize "#{max_dimension}x#{max_dimension}>"
      end

      # Optimize the image
      image.strip # Remove EXIF data
      image.quality 100 # Good balance of quality and file size

      # Read the processed image data
      File.binread(image.path)
    ensure
      temp_file.close
      temp_file.unlink
    end
  end
end


# shop = Shop.first
# image = shop.kuralis_products.first.images.first

# service = EbayImageUploadService.new(shop)
# service.upload_image(image)
