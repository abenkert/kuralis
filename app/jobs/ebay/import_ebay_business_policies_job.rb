module Ebay
  class ImportEbayBusinessPoliciesJob < ApplicationJob
    queue_as :default

    def perform(shop_id)
      Ebay::ImportEbayPaymentProfilesJob.perform_now(shop_id)
      Ebay::ImportEbayReturnProfilesJob.perform_now(shop_id)
      Ebay::ImportShippingPoliciesJob.perform_now(shop_id)
    end
  end
end
