# frozen_string_literal: true

class HomeController < ApplicationController
  include ShopifyApp::EmbeddedApp
  include ShopifyApp::EnsureInstalled
  include ShopifyApp::ShopAccessScopesVerification

  def index
    @shop_origin = current_shopify_domain
    @host = params[:host]

    if ShopifyAPI::Context.embedded? && (!params[:embedded].present? || params[:embedded] != "1")
      redirect_to(ShopifyAPI::Auth.embedded_app_url(params[:host]) + request.path, allow_other_host: true)
    else
      # Try to find the shop record
      shop = Shop.find_by(shopify_domain: @shop_origin)

      if shop && shop.shopify_token.present?
        # If we have a shop and token, redirect to dashboard
        redirect_to dashboard_path
      elsif params[:shop].present?
        # If we don't have a valid session but have a shop param,
        # we'll get redirected to login by the ShopAccessScopesVerification concern
        # This is just a placeholder - the redirect is handled by the concern
        render :index
      else
        # If we don't have a shop param at all, show the login page
        redirect_to login_path
      end
    end
  end
end
