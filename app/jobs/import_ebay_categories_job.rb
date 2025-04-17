class ImportEbayCategoriesJob < ApplicationJob
  queue_as :default

  def perform(shop_id, marketplace_id = 'EBAY_US')
    # Find the eBay account
    ebay_account = ShopifyEbayAccount.find_by(shop_id: shop_id)
    
    begin
      # Use our service to import categories
      importer = Ebay::CategoryImporter.new(ebay_account, marketplace_id)
      result = importer.import_categories
      
      if result[:success]
        # Create a notification for the user
        Notification.create!(
          shop_id: ebay_account.shop_id,
          title: 'eBay Categories Imported',
          message: "Successfully imported #{result[:count]} eBay categories for marketplace #{marketplace_id}.",
          category: 'ebay_integration'
        )
      else
        # Create an error notification
        Notification.create!(
          shop_id: ebay_account.shop_id,
          title: 'eBay Category Import Failed',
          message: "Failed to import eBay categories: #{result[:error]}",
          category: 'ebay_integration'
        )
      end
    rescue => e
      # Create an error notification
      Notification.create!(
        shop_id: ebay_account.shop_id,
        title: 'eBay Category Import Failed',
        message: "An unexpected error occurred: #{e.message}",
        category: 'ebay_integration'
      )
      
      # Re-raise the error for job retry mechanisms
      raise
    end
  end
end
