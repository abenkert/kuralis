class AfterAuthenticateJob < ApplicationJob
  queue_as :default

  def perform(args)
    # Handle both string and hash arguments
    shop_domain = args.is_a?(Hash) ? args[:shop_domain] : args
    return unless shop_domain.present?

    # Find or create the shop record
    shop = Shop.find_by(shopify_domain: shop_domain)

    unless shop
      Rails.logger.info("Shop not found in AfterAuthenticateJob, creating new shop for #{shop_domain}")
      # You should create a shop record here if it doesn't exist
      # This should never actually happen because ShopifyApp should have created it,
      # but we add it as a safeguard
      shop = Shop.create!(shopify_domain: shop_domain)
    end

    # Ensure the shop has the necessary scopes to avoid the login_on_scope_changes redirect
    begin
      # Update scopes to match what's configured in the ShopifyApp initializer
      shop.access_scopes = ShopifyApp.configuration.scope
      shop.save!

      # Force a token refresh if needed
      if shop.shopify_token.blank?
        # This is just logging - we can't actually refresh the token here
        # The user will need to go through auth again
        Rails.logger.info("Shop #{shop_domain} has no token, will need to re-auth")
      end
    rescue => e
      Rails.logger.error("Error updating shop scopes: #{e.message}")
    end

    # Add any post-authentication setup needed here
    # This will run after a successful authentication
    Rails.logger.info("Successfully completed AfterAuthenticateJob for shop: #{shop_domain}")
  end
end
