# frozen_string_literal: true

class AuthenticatedController < ApplicationController
  include ShopifyApp::EnsureHasSession

  helper_method :current_shop
  
  protected 
  
  def current_shop
    @current_shop ||= Shop.find_by(shopify_domain: current_shopify_domain)
  end
end

