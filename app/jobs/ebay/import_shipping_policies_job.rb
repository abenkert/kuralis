module Ebay
  class ImportShippingPoliciesJob < ApplicationJob
    queue_as :default

    def perform(shop_id)
      shop = Shop.find(shop_id)
      service = EbayFulfillmentService.new(shop)

      result = service.fetch_policies

      if result[:success]
        Rails.logger.info "Successfully imported shipping policies for shop #{shop_id}"
      else
        Rails.logger.error "Failed to import shipping policies for shop #{shop_id}: #{result[:error]}"
      end
    end
  end
end
