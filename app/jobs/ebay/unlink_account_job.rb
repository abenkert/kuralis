class Ebay::UnlinkAccountJob < ApplicationJob
  queue_as :default

  def perform(shop_id)
    shop = Shop.find(shop_id)
    ebay_account = shop.shopify_ebay_account
    
    return unless ebay_account

    begin
      # First, unsubscribe from notifications
      # TODO: This is not functional. A change needs to be made to the notification endpoint url.
      # unsubscribe_from_notifications(shop)


      # TODO: This is not functional really. Tokens dont need to be revoked? Not sure how to do this.
      revoke_oauth_tokens(ebay_account)

      ebay_account.destroy!

      Rails.logger.info "Successfully unlinked eBay account for shop #{shop_id}"
    rescue => e
      Rails.logger.error "Failed to unlink eBay account for shop #{shop_id}: #{e.message}"
      raise e
    end
  end

  private

  def revoke_oauth_tokens(ebay_account)
    uri = URI('https://api.ebay.com/identity/v1/oauth2/token/revoke')
    
    # Revoke access token
    revoke_token(uri, ebay_account.access_token) if ebay_account.access_token.present?
    
    # Revoke refresh token
    revoke_token(uri, ebay_account.refresh_token) if ebay_account.refresh_token.present?
  rescue => e
    Rails.logger.error "Failed to revoke eBay OAuth tokens: #{e.message}"
    # Continue with unlinking even if token revocation fails
  end

  def revoke_token(uri, token)
    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/x-www-form-urlencoded'
    request['Authorization'] = "Basic #{Base64.strict_encode64("#{ENV['EBAY_CLIENT_ID']}:#{ENV['EBAY_CLIENT_SECRET']}")}"
    request.body = "token=#{token}"

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
      http.request(request)
    end

    Rails.logger.info "eBay token revocation response: #{response.body}"
  end

  # TODO: This is not functional. A change needs to be made to the notification endpoint url.

#   def unsubscribe_from_notifications(shop)
#     notification_types = ['AuctionCheckoutComplete']
#     token = EbayTokenService.new(shop).fetch_or_refresh_access_token

#     uri = URI('https://api.ebay.com/ws/api.dll')
    
#     notification_types.each do |notification_type|
#       xml_request = build_disable_notification_request(notification_type)

#       headers = {
#         'X-EBAY-API-COMPATIBILITY-LEVEL' => '967',
#         'X-EBAY-API-IAF-TOKEN' => token,
#         'X-EBAY-API-CALL-NAME' => 'SetNotificationPreferences',
#         'X-EBAY-API-SITEID' => '0',
#         'Content-Type' => 'text/xml'
#       }

#       response = Net::HTTP.post(uri, xml_request, headers)
#       Rails.logger.info "eBay notification unsubscribe response for #{notification_type}: #{response.body}"
#     end
#   rescue => e
#     Rails.logger.error "Failed to unsubscribe from eBay notifications: #{e.message}"
#     # Continue with unlinking even if unsubscribe fails
#   end

#   def build_disable_notification_request(notification_type)
#     <<~XML
#       <?xml version="1.0" encoding="utf-8"?>
#       <SetNotificationPreferencesRequest xmlns="urn:ebay:apis:eBLBaseComponents">
#         <RequesterCredentials>
#           <eBayAuthToken>${token}</eBayAuthToken>
#         </RequesterCredentials>
#         <ApplicationDeliveryPreferences>
#           <ApplicationEnable>Disable</ApplicationEnable>
#           <ApplicationURL>#{shop.notification_endpoint_url}</ApplicationURL>
#         </ApplicationDeliveryPreferences>
#         <UserDeliveryPreferenceArray>
#           <NotificationEnable>
#             <EventType>#{notification_type}</EventType>
#             <EventEnable>Disable</EventEnable>
#           </NotificationEnable>
#         </UserDeliveryPreferenceArray>
#       </SetNotificationPreferencesRequest>
#     XML
#   end
end 