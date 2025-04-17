class EbayFulfillmentService
  def initialize(shop)
    @shop = shop
    @ebay_account = shop.shopify_ebay_account
    @token_service = EbayTokenService.new(shop)
  end

  def fetch_policies
    access_token = @token_service.fetch_or_refresh_access_token
    
    uri = URI('https://api.ebay.com/sell/account/v1/fulfillment_policy?marketplace_id=EBAY_US')
    
    # TODO: Figure out why we didnt have permissions for our
    headers = {
      'Authorization' => "Bearer #{access_token}",
      'Content-Type' => 'application/json'
    }

    begin
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        request = Net::HTTP::Get.new(uri, headers)
        http.request(request)
      end

      if response.is_a?(Net::HTTPSuccess)
        policies = JSON.parse(response.body)['fulfillmentPolicies']
        update_shipping_profiles(policies)
        Rails.logger.info "Successfully fetched and updated #{policies.size} shipping policies"
        { success: true, policies: policies }
      else
        Rails.logger.error "Failed to fetch shipping policies: #{response.body}"
        { success: false, error: "HTTP #{response.code}: #{response.body}" }
      end
    rescue => e
      Rails.logger.error "Error fetching shipping policies: #{e.message}"
      { success: false, error: e.message }
    end
  end

  private

  def update_shipping_profiles(new_policies)
    formatted_policies = new_policies.map do |policy|
      {
        'id' => policy['fulfillmentPolicyId'],
        'name' => policy['name']
      }
    end

    # Get the new policy IDs
    new_policy_ids = formatted_policies.map { |p| p['id'] }
    
    # Get the existing policy IDs
    existing_policy_ids = @ebay_account.shipping_profiles.map { |p| p['id'] }
    
    # Find policies that no longer exist
    removed_policy_ids = existing_policy_ids - new_policy_ids
    
    if removed_policy_ids.any?
      # Remove weights for deleted policies
      removed_policy_ids.each do |policy_id|
        @ebay_account.shipping_profile_weights.delete(policy_id)
      end
      Rails.logger.info "Removed #{removed_policy_ids.size} obsolete shipping policies"
    end

    # Update the shipping profiles
    @ebay_account.update(
      shipping_profiles: formatted_policies,
      shipping_profile_weights: @ebay_account.shipping_profile_weights.slice(*new_policy_ids)
    )
  end
end 