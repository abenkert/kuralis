module Ebay
  class AuthController < Ebay::BaseController
    def auth
      service = EbayOauthService.new
      redirect_to service.authorization_url, allow_other_host: true
    end

    def callback
      auth_code = params[:code]
      if auth_code.nil?
        flash[:alert] = "Authorization code is missing"
        redirect_to dashboard_path
        return
      end

      service = EbayOauthService.new
      response = service.fetch_access_token(auth_code)

      if response.code == 200
        access_token = response.parsed_response["access_token"]
        refresh_token = response.parsed_response["refresh_token"]
        expires_in = response.parsed_response["expires_in"]
        refresh_token_expires_in = response.parsed_response["refresh_token_expires_in"]

        shop_domain = current_shopify_domain
        shop = Shop.find_by(shopify_domain: shop_domain)

        linked_ebay_account = ShopifyEbayAccount.find_by(shop: shop)

        if linked_ebay_account
          flash[:alert] = "eBay account already linked."
        elsif shop
          shop.create_shopify_ebay_account!(
            access_token: access_token,
            access_token_expires_at: Time.current + expires_in.seconds,
            refresh_token: refresh_token,
            refresh_token_expires_at: Time.current + refresh_token_expires_in.seconds
          )
          flash[:notice] = "eBay account linked successfully!"
        else
          flash[:alert] = "Shop not found. Please try again."
        end
      else
        flash[:alert] = "Failed to link eBay account. Please try again."
      end

      # Subscribe to notifications after successful authentication
      EbayNotificationService.subscribe_to_notifications(shop)
      Ebay::ImportEbayBusinessPoliciesJob.perform_later(shop.id)

      redirect_to dashboard_path, notice: "eBay account connected successfully"
    rescue StandardError => e
      redirect_to settings_path, alert: "Failed to connect eBay account: #{e.message}"
    end

    def destroy
      Ebay::UnlinkAccountJob.perform_later(current_shop.id)

      respond_to do |format|
        format.html do
          flash[:notice] = "eBay account unlink process started."
          redirect_to settings_path
        end
        format.turbo_stream do
          flash.now[:notice] = "eBay account unlink process started."
        end
      end
    end
  end
end
