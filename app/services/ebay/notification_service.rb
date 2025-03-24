module Ebay
  class NotificationService
    # Available notification types according to eBay's documentation
    AVAILABLE_NOTIFICATION_TYPES = [
      "AuctionCheckoutComplete",
      "ItemListed",
      "ItemSold",
      "FixedPriceTransaction",
      "ItemRevised",
      "CheckoutBuyerRequestTotal",
      "ItemMarkedShipped",
      "ItemMarkedPaid",
      "BidReceived",
      "FeedbackReceived",
      "AuctionCreated",
      "BestOffer"
    ].freeze

    # Notification types currently being used
    NOTIFICATION_TYPES = [
      "AuctionCheckoutComplete",
      "ItemListed",
      "ItemSold",
      "ItemRevised"
    ].freeze

    def initialize(shop)
      @shop = shop
      @token = EbayTokenService.new(@shop).fetch_or_refresh_access_token
    end

    def register_notifications
      response = make_request(build_register_payload)
      Rails.logger.info "eBay Notification Registration Response: #{response.body}"
      response
    end

    # Get current notification preferences
    def get_notification_preferences
      response = make_request(build_get_preferences_payload)
      Rails.logger.info "eBay Get Notification Preferences Response: #{response.body}"
      response
    end

    # Test notifications by sending a ping to your endpoint
    def test_notifications
      response = make_request(build_test_payload)
      Rails.logger.info "eBay Test Notification Response: #{response.body}"
      response
    end

    private

    def build_register_payload
      <<~XML
        <?xml version="1.0" encoding="utf-8"?>
        <SetNotificationPreferencesRequest xmlns="urn:ebay:apis:eBLBaseComponents">
          <RequesterCredentials>
            <eBayAuthToken>#{@token}</eBayAuthToken>
          </RequesterCredentials>
          <ApplicationDeliveryPreferences>
            <ApplicationURL>#{notification_url}</ApplicationURL>
            <ApplicationEnable>Enable</ApplicationEnable>
            <NotificationPayloadType>eBLSchemaSOAP</NotificationPayloadType>
            <DeviceType>Platform</DeviceType>
          </ApplicationDeliveryPreferences>
          <UserDeliveryPreferenceArray>
            #{build_notification_preferences}
          </UserDeliveryPreferenceArray>
        </SetNotificationPreferencesRequest>
      XML
    end

    def build_get_preferences_payload
      <<~XML
        <?xml version="1.0" encoding="utf-8"?>
        <GetNotificationPreferencesRequest xmlns="urn:ebay:apis:eBLBaseComponents">
          <RequesterCredentials>
            <eBayAuthToken>#{@token}</eBayAuthToken>
          </RequesterCredentials>
          <PreferenceLevel>User</PreferenceLevel>
        </GetNotificationPreferencesRequest>
      XML
    end

    def build_test_payload
      <<~XML
        <?xml version="1.0" encoding="utf-8"?>
        <SetNotificationPreferencesRequest xmlns="urn:ebay:apis:eBLBaseComponents">
          <RequesterCredentials>
            <eBayAuthToken>#{@token}</eBayAuthToken>
          </RequesterCredentials>
          <DeliveryURLName>#{notification_url}</DeliveryURLName>
          <EventType>ItemListed</EventType>
        </SetNotificationPreferencesRequest>
      XML
    end

    def build_notification_preferences
      NOTIFICATION_TYPES.map do |type|
        <<~XML
          <NotificationEnable>
            <EventType>#{type}</EventType>
            <EventEnable>Enable</EventEnable>
          </NotificationEnable>
        XML
      end.join
    end

    def make_request(payload)
      uri = URI.parse("https://api.ebay.com/ws/api.dll")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      request = Net::HTTP::Post.new(uri.path)
      request["X-EBAY-API-COMPATIBILITY-LEVEL"] = "967"

      # Set the call name based on the payload
      if payload.include?("GetNotificationPreferences")
        request["X-EBAY-API-CALL-NAME"] = "GetNotificationPreferences"
      else
        request["X-EBAY-API-CALL-NAME"] = "SetNotificationPreferences"
      end

      request["X-EBAY-API-SITEID"] = "0"

      # Use the environment variables we have, transforming them as needed
      request["X-EBAY-API-APP-NAME"] = ENV.fetch("EBAY_CLIENT_ID") { raise "EBAY_CLIENT_ID not set" }
      request["X-EBAY-API-DEV-NAME"] = ENV.fetch("EBAY_DEV_ID") { raise "EBAY_DEV_ID not set" }
      request["X-EBAY-API-CERT-NAME"] = ENV.fetch("EBAY_CLIENT_SECRET") { raise "EBAY_CLIENT_SECRET not set" }

      request["Content-Type"] = "text/xml;charset=utf-8"

      Rails.logger.info "eBay API Request Headers: #{request.to_hash}"
      Rails.logger.info "eBay API Request Payload: #{payload}"

      request.body = payload
      http.request(request)
    end

    def notification_url
      # This needs to be a publicly accessible URL
      Rails.application.routes.url_helpers.ebay_notifications_url(
        host: ENV.fetch("APPLICATION_HOST") { raise "APPLICATION_HOST not set" },
        protocol: "https"
      )
    end
  end
end
