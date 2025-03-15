module Ebay
  class CategoryImporter
    attr_reader :marketplace_id, :ebay_account, :shop

    def initialize(ebay_account, marketplace_id = 'EBAY_US')
      @ebay_account = ebay_account
      @shop = ebay_account.shop
      @marketplace_id = marketplace_id
      @token_service = EbayTokenService.new(@shop)
    end

    def import_categories
      Rails.logger.info "Starting eBay category import for marketplace #{marketplace_id}"
      
      begin
        # Fetch categories from eBay API
        categories = fetch_categories_from_api
        
        # Process and save categories
        process_categories(categories)
        
        Rails.logger.info "Successfully imported #{categories.size} eBay categories"
        { success: true, count: categories.size }
      rescue => e
        Rails.logger.error "Error importing eBay categories: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        { success: false, error: e.message }
      end
    end

    private

    def fetch_categories_from_api
      token = @token_service.fetch_or_refresh_access_token
      
      uri = URI('https://api.ebay.com/ws/api.dll')
      
      headers = {
        'X-EBAY-API-COMPATIBILITY-LEVEL' => '967',
        'X-EBAY-API-IAF-TOKEN' => token,
        'X-EBAY-API-CALL-NAME' => 'GetCategories',
        'X-EBAY-API-SITEID' => '0', # US site ID
        'Content-Type' => 'text/xml'
      }

      xml_request = build_get_categories_request

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        request = Net::HTTP::Post.new(uri, headers)
        request.body = xml_request
        http.request(request)
      end

      if response.is_a?(Net::HTTPSuccess)
        doc = Nokogiri::XML(response.body)

        namespace = { "ebay" => "urn:ebay:apis:eBLBaseComponents" }
        category_count = doc.xpath('//ebay:CategoryCount', namespace).text.to_i
        Rails.logger.info "Fetched #{category_count} categories from eBay API"
        
        parse_categories(doc, namespace)
      else
        Rails.logger.error "Failed to fetch categories: #{response.body}"
        raise "HTTP #{response.code}: #{response.body}"
      end
    end
    
    def build_get_categories_request
      <<~XML
        <?xml version="1.0" encoding="utf-8"?>
        <GetCategoriesRequest xmlns="urn:ebay:apis:eBLBaseComponents">
          <RequesterCredentials>
            <eBayAuthToken>#{@token_service.fetch_or_refresh_access_token}</eBayAuthToken>
          </RequesterCredentials>
          <DetailLevel>ReturnAll</DetailLevel>
          <ViewAllNodes>true</ViewAllNodes>
        </GetCategoriesRequest>
      XML
    end
    
    def parse_categories(doc, namespace)
      categories = []
      
      doc.xpath('//ebay:Category', namespace).each do |category|
        category_id = category.at_xpath('.//ebay:CategoryID', namespace)&.text
        name = category.at_xpath('.//ebay:CategoryName', namespace)&.text
        parent_id = category.at_xpath('.//ebay:CategoryParentID', namespace)&.text
        level = category.at_xpath('.//ebay:CategoryLevel', namespace)&.text.to_i
        leaf = category.at_xpath('.//ebay:LeafCategory', namespace)&.text == 'true'
        
        next if category_id.blank? || name.blank?
        
        # Previously we skipped root categories (where category_id == parent_id)
        # Now we include them to ensure complete category paths for better matching with AI suggestions
        # next if category_id == parent_id
        
        categories << {
          category_id: category_id,
          name: name,
          parent_id: parent_id == '0' ? nil : parent_id,
          level: level,
          leaf: leaf,
          best_offer_enabled: category.at_xpath('.//ebay:BestOfferEnabled', namespace)&.text == 'true',
          auto_pay_enabled: category.at_xpath('.//ebay:AutoPayEnabled', namespace)&.text == 'true'
        }
      end
      
      Rails.logger.info "Parsed #{categories.size} categories from eBay API"
      categories
    end

    def process_categories(categories)
      # Start a transaction to ensure data consistency
      ActiveRecord::Base.transaction do
        # Optionally clear existing categories for this marketplace
        # Uncomment if you want to replace all categories each time
        # EbayCategory.where(marketplace_id: marketplace_id).delete_all
        
        # Process each category
        categories.each do |category_data|
          process_category(category_data)
        end
      end
    end

    def process_category(category_data)
      # Find existing category or create new one
      category = EbayCategory.find_or_initialize_by(
        category_id: category_data[:category_id],
        marketplace_id: marketplace_id
      )
      
      # Update attributes and save
      category.update!(
        name: category_data[:name],
        parent_id: category_data[:parent_id],
        level: category_data[:level],
        leaf: category_data[:leaf],
        metadata: {
          best_offer_enabled: category_data[:best_offer_enabled],
          auto_pay_enabled: category_data[:auto_pay_enabled]
        }
      )
    end
  end
end 