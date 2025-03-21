module Ebay
  class ImportEbayPaymentProfilesJob < ApplicationJob
    queue_as :default

    def perform(shop_id)
      shop = Shop.find(shop_id)
      ebay_account = shop.shopify_ebay_account
      return unless ebay_account

      token_service = EbayTokenService.new(shop)
      token = token_service.fetch_or_refresh_access_token

      uri = URI("https://api.ebay.com/sell/account/v1/payment_policy?marketplace_id=EBAY_US")

      headers = {
        "Authorization" => "Bearer #{token}",
        "Content-Type" => "application/json",
        "Accept" => "application/json"
      }

      begin
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
          request = Net::HTTP::Get.new(uri, headers)
          http.request(request)
        end

        if response.is_a?(Net::HTTPSuccess)
          payment_policies = JSON.parse(response.body)

          if payment_policies["paymentPolicies"].present?
            payment_profiles = parse_payment_policies(payment_policies["paymentPolicies"])

            ebay_account.update!(
              payment_profiles: payment_profiles
            )

            Rails.logger.info "Successfully imported #{payment_profiles.size} payment policies"
          else
            Rails.logger.error "No payment policies found"
          end
        else
          error_response = JSON.parse(response.body) rescue nil
          error_message = error_response&.dig("errors", 0, "message") || "HTTP Error #{response.code}"
          Rails.logger.error "eBay API Error: #{error_message}"
        end
      rescue => e
        Rails.logger.error "Error importing payment policies: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
      end
    end

    private

    def parse_payment_policies(policies)
      policies.map do |policy|
        {
          "profile_id" => policy["paymentPolicyId"],
          "profile_name" => policy["name"],
          "payment_methods" => parse_payment_methods(policy),
          "is_default" => policy["marketplaceId"] == "EBAY_US" && policy["categoryTypes"].any? { |ct| ct["default"] },
          "description" => policy["description"],
          "immutable" => policy["immutable"],
          "payment_instructions" => policy["paymentInstructions"]
        }
      end
    end

    def parse_payment_methods(policy)
      methods = []
      methods << "PAYPAL" if policy["payPalRequired"]
      methods.concat(policy["paymentMethods"].map { |pm| pm["paymentMethodType"] }) if policy["paymentMethods"]
      methods
    end
  end
end
