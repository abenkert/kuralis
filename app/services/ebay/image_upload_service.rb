module Ebay
  class ImageUploadService
    def initialize(shop)
      @shop = shop
      @token_service = EbayTokenService.new(@shop)
    end

    # Main method for handling different types of image inputs
    def upload_image(input)
      case input
      when String # URL
        upload_from_url(input)
      when Tempfile, File
        upload_from_file(input)
      when ActionDispatch::Http::UploadedFile
        upload_from_file(input)
      when ActiveStorage::Blob
        upload_from_blob(input)
      else
        Rails.logger.error "Unsupported image input type: #{input.class}"
        { success: false, error: "Unsupported image input type" }
      end
    end

    private

    def upload_from_url(url)
      begin
        tempfile = Down.download(url)
        result = upload_from_file(tempfile)
        result
      rescue => e
        Rails.logger.error "Failed to download image from URL: #{e.message}"
        { success: false, error: "Failed to download image: #{e.message}" }
      ensure
        tempfile&.close
        tempfile&.unlink
      end
    end

    def upload_from_blob(blob)
      tempfile = Tempfile.new([ "ebay_image", File.extname(blob.filename.to_s) ])
      begin
        tempfile.binmode
        tempfile.write(blob.download)
        tempfile.rewind
        result = upload_from_file(tempfile)
        result
      rescue => e
        Rails.logger.error "Failed to process blob: #{e.message}"
        { success: false, error: "Failed to process blob: #{e.message}" }
      ensure
        tempfile&.close
        tempfile&.unlink
      end
    end

    def upload_from_file(file)
      token = @token_service.fetch_or_refresh_access_token
      uri = URI("https://api.ebay.com/ws/api.dll")
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

      filename = file.respond_to?(:original_filename) ? file.original_filename : File.basename(file.path)

      xml_request = <<~XML
        <?xml version="1.0" encoding="utf-8"?>
        <UploadSiteHostedPicturesRequest xmlns="urn:ebay:apis:eBLBaseComponents">
          <RequesterCredentials>
            <eBayAuthToken>#{token}</eBayAuthToken>
          </RequesterCredentials>
          <PictureName>#{CGI.escapeHTML(filename)}</PictureName>
        </UploadSiteHostedPicturesRequest>
      XML

      post_body = []
      post_body << "--#{boundary}"
      post_body << "Content-Disposition: form-data; name=\"XML Payload\""
      post_body << "Content-Type: text/xml;charset=utf-8"
      post_body << ""
      post_body << xml_request
      post_body << "--#{boundary}"
      post_body << "Content-Disposition: form-data; name=\"Image\"; filename=\"#{filename}\""
      post_body << "Content-Type: image/jpeg"
      post_body << "Content-Transfer-Encoding: binary"
      post_body << ""
      post_body << File.binread(file.path)
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
            { success: false, error: error_message }
          end
        else
          Rails.logger.error "HTTP Error in image upload: #{response.code} - #{response.body}"
          { success: false, error: "HTTP Error #{response.code}" }
        end
      rescue => e
        Rails.logger.error "Error uploading image: #{e.message}"
        { success: false, error: e.message }
      end
    end
  end
end


# shop = Shop.first
# image = shop.kuralis_products.first.images.first

# service = EbayImageUploadService.new(shop)
# service.upload_image(image)
