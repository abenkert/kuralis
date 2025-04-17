# TODO: This is not functional. A change needs to be made to the notification endpoint url.
class EbayNotificationService
  def self.subscribe_to_notifications(shop)
    ebay_account = shop.shopify_ebay_account
    token = EbayTokenService.new(shop).fetch_or_refresh_access_token

    notification_types = [
      'AuctionCheckoutComplete'     # Buyer has completed checkout
    ]

    uri = URI('https://api.ebay.com/ws/api.dll')
    
    notification_types.each do |notification_type|
      xml_request = build_subscription_request(notification_type, shop.notification_endpoint_url)

      headers = {
        'X-EBAY-API-COMPATIBILITY-LEVEL' => '967',
        'X-EBAY-API-IAF-TOKEN' => token,
        'X-EBAY-API-CALL-NAME' => 'SetNotificationPreferences',
        'X-EBAY-API-SITEID' => '0',
        'Content-Type' => 'text/xml'
      }

      response = Net::HTTP.post(uri, xml_request, headers)
      
      Rails.logger.info("eBay notification subscription response for #{notification_type}: #{response.body}")
    end
  end

  private

  def self.build_subscription_request(notification_type, endpoint_url)
    <<~XML
      <?xml version="1.0" encoding="utf-8"?>
      <SetNotificationPreferencesRequest xmlns="urn:ebay:apis:eBLBaseComponents">
        <ApplicationDeliveryPreferences>
          <ApplicationEnable>Enable</ApplicationEnable>
          <ApplicationURL>#{endpoint_url}</ApplicationURL>
          <DeviceType>Platform</DeviceType>
        </ApplicationDeliveryPreferences>
        <UserDeliveryPreferenceArray>
          <NotificationEnable>
            <EventType>#{notification_type}</EventType>
            <EventEnable>Enable</EventEnable>
          </NotificationEnable>
        </UserDeliveryPreferenceArray>
        <Version>967</Version>
      </SetNotificationPreferencesRequest>
    XML
  end
end 