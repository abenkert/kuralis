module Ebay
  class ImportEbayReturnProfilesJob < ApplicationJob
    queue_as :default

    def perform(shop_id)
      shop = Shop.find(shop_id)
      ebay_account = shop.shopify_ebay_account
      return unless ebay_account

      token_service = EbayTokenService.new(shop)
      token = token_service.fetch_or_refresh_access_token

      uri = URI("https://api.ebay.com/sell/account/v1/return_policy?marketplace_id=EBAY_US")

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
          return_policies = JSON.parse(response.body)

          if return_policies["returnPolicies"].present?
            return_profiles = parse_return_policies(return_policies["returnPolicies"])

            ebay_account.update!(
              return_profiles: return_profiles
            )

            Rails.logger.info "Successfully imported #{return_profiles.size} return policies"
          else
            Rails.logger.error "No return policies found"
          end
        else
          error_response = JSON.parse(response.body) rescue nil
          error_message = error_response&.dig("errors", 0, "message") || "HTTP Error #{response.code}"
          Rails.logger.error "eBay API Error: #{error_message}"
        end
      rescue => e
        Rails.logger.error "Error importing return policies: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
      end
    end

    private

    def parse_return_policies(policies)
      policies.map do |policy|
        {
          "profile_id" => policy["returnPolicyId"],
          "profile_name" => policy["name"],
          "returns_accepted" => policy["returnsAccepted"],
          "refund_option" => policy["refundMethod"],
          "shipping_cost_paid_by" => policy["returnShippingCostPayer"],
          "description" => policy["description"]
        }
      end
    end
  end
end
