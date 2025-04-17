module Ebay
  class ImportStoreCategoriesJob < ApplicationJob
    queue_as :default

    def perform(shop_id)
      shop = Shop.find(shop_id)
      service = EbayStoreService.new(shop)
      
      result = service.fetch_store_categories
      
      if result[:success]
        Rails.logger.info "Successfully imported store categories for shop #{shop_id}"
      else
        Rails.logger.error "Failed to import store categories for shop #{shop_id}: #{result[:error]}"
      end
    end
  end
end 