class EbayTokenService
  def initialize(shop)
    @shop = shop
    @ebay_account = shop.shopify_ebay_account
  end

  def fetch_or_refresh_access_token
    if @ebay_account.access_token_expires_at > Time.current
      @ebay_account.access_token
    else
      refresh_access_token
      @ebay_account.access_token
    end
  end

  def save_tokens(access_token, refresh_token, expires_in, refresh_token_expires_in)
    @ebay_account.update!(
      access_token: access_token,
      access_token_expires_at: Time.current + expires_in.seconds,
      refresh_token: refresh_token,
      refresh_token_expires_at: Time.current + refresh_token_expires_in.seconds
    )
  end

  def refresh_access_token
    return unless @ebay_account.refresh_token_expires_at > Time.current

    response = fetch_new_access_token(@ebay_account.refresh_token)
    if response.code == 200
      new_access_token = response.parsed_response['access_token']
      expires_in = response.parsed_response['expires_in']
      save_tokens(new_access_token, @ebay_account.refresh_token, expires_in, @ebay_account.refresh_token_expires_at.to_i - Time.current.to_i)
    else
      Rails.logger.error("Failed to refresh access token: #{response.body}")
    end
  end

  private

  def fetch_new_access_token(refresh_token)
    service = EbayOauthService.new
    service.fetch_access_token_with_refresh_token(refresh_token)
  end
end 