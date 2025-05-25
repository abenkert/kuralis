module Ebay
  class InventoryService
    attr_reader :ebay_listing, :product, :shop

    def initialize(ebay_listing, kuralis_product)
      @ebay_listing = ebay_listing
      @product = kuralis_product
      @shop = @product.shop
      @token_service = EbayTokenService.new(@shop)
    end

    def update_inventory
      if @product.base_quantity <= 0 || @product.status != "active"
        end_listing
      else
        update_listing
      end
    end

    private

    def update_listing
      result = make_api_call("ReviseFixedPriceItem", build_revise_request)

      if result[:success]
        Rails.logger.info "Successfully updated eBay listing #{@ebay_listing.ebay_item_id}"

        # Calculate the new total_quantity to maintain the validation constraint
        # quantity = total_quantity - quantity_sold
        # Therefore: total_quantity = quantity + quantity_sold
        new_total_quantity = @product.base_quantity + @ebay_listing.quantity_sold

        @ebay_listing.update(
          quantity: @product.base_quantity,
          total_quantity: new_total_quantity,
          ebay_status: "active"
        )
        true
      else
        Rails.logger.error "Failed to update eBay listing: #{result[:error]}"
        false
      end
    end

    def end_listing
      end_service = Ebay::EndListingService.new(@ebay_listing)
      end_service.end_listing("NotAvailable")
    end

    def build_revise_request
      <<~XML
        <?xml version="1.0" encoding="utf-8"?>
        <ReviseFixedPriceItemRequest xmlns="urn:ebay:apis:eBLBaseComponents">
          <RequesterCredentials>
            <eBayAuthToken>#{@token_service.fetch_or_refresh_access_token}</eBayAuthToken>
          </RequesterCredentials>
          <Item>
            <ItemID>#{@ebay_listing.ebay_item_id}</ItemID>
            <Quantity>#{@product.base_quantity}</Quantity>
          </Item>
        </ReviseFixedPriceItemRequest>
      XML
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

          ack = doc.at_xpath("//ebay:Ack", namespace)&.text
          if ack == "Success" || ack == "Warning"
            { success: true, response: doc }
          else
            error_message = doc.at_xpath("//ebay:Errors/ebay:ShortMessage", namespace)&.text || "Unknown error"
            { success: false, error: error_message }
          end
        else
          { success: false, error: "HTTP Error #{response.code}" }
        end
      rescue => e
        Rails.logger.error "Error in #{call_name}: #{e.message}"
        { success: false, error: e.message }
      end
    end
  end
end
