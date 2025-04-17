class AfterAuthenticateJob < ApplicationJob
  queue_as :default

  def perform(args)
    # Handle both string and hash arguments
    shop_domain = args.is_a?(Hash) ? args[:shop_domain] : args
    return unless shop_domain.present?

    shop = Shop.find_by(shopify_domain: shop_domain)
    return unless shop

    # Add any post-authentication setup needed
    # But skip user creation for now
  end
end
