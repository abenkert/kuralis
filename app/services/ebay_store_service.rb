class EbayStoreService
  def initialize(shop)
    @shop = shop
    @ebay_account = shop.shopify_ebay_account
    @token_service = EbayTokenService.new(shop)
  end

  def fetch_store_categories
    token = @token_service.fetch_or_refresh_access_token
    
    uri = URI('https://api.ebay.com/ws/api.dll')
    
    headers = {
      'X-EBAY-API-COMPATIBILITY-LEVEL' => '967',
      'X-EBAY-API-IAF-TOKEN' => token,
      'X-EBAY-API-CALL-NAME' => 'GetStore',
      'X-EBAY-API-SITEID' => '0',
      'Content-Type' => 'text/xml'
    }

    xml_request = build_get_store_request

    begin
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        request = Net::HTTP::Post.new(uri, headers)
        request.body = xml_request
        http.request(request)
      end

      if response.is_a?(Net::HTTPSuccess)
        doc = Nokogiri::XML(response.body)
        namespace = { "ebay" => "urn:ebay:apis:eBLBaseComponents" }
        
        if doc.at_xpath('//ebay:Store/ebay:CustomCategories', namespace)
          categories = parse_store_categories(doc, namespace)
          update_store_categories(categories)
          Rails.logger.info "Successfully fetched and updated #{categories.size} store categories"
          { success: true, categories: categories }
        else
          Rails.logger.error "No custom categories found in store"
          { success: false, error: "No custom categories found" }
        end
      else
        Rails.logger.error "Failed to fetch store categories: #{response.body}"
        { success: false, error: "HTTP #{response.code}: #{response.body}" }
      end
    rescue => e
      Rails.logger.error "Error fetching store categories: #{e.message}"
      { success: false, error: e.message }
    end
  end

  private

  def build_get_store_request
    <<~XML
      <?xml version="1.0" encoding="utf-8"?>
      <GetStoreRequest xmlns="urn:ebay:apis:eBLBaseComponents">
        <RequesterCredentials>
          <eBayAuthToken>#{@token_service.fetch_or_refresh_access_token}</eBayAuthToken>
        </RequesterCredentials>
        <CategoryStructureOnly>true</CategoryStructureOnly>
      </GetStoreRequest>
    XML
  end

  def parse_store_categories(doc, namespace)
    categories = []
    
    # Parse parent categories
    doc.xpath('//ebay:CustomCategory', namespace).each do |category|
      category_data = {
        'id' => category.at_xpath('.//ebay:CategoryID', namespace).text,
        'name' => category.at_xpath('.//ebay:Name', namespace).text,
        'order' => category.at_xpath('.//ebay:Order', namespace).text.to_i  # Convert to integer for proper sorting
      }
    # TODO: Check for child categories if we neeed them.
    #   child_categories = category.xpath('.//ebay:ChildCategory', namespace)
    #   if child_categories.any?
    #     category_data['children'] = child_categories.map do |child|
    #       {
    #         'id' => child.at_xpath('.//ebay:CategoryID', namespace).text,
    #         'name' => child.at_xpath('.//ebay:Name', namespace).text,
    #         'order' => child.at_xpath('.//ebay:Order', namespace).text,
    #         'parent_id' => category_data['id']
    #       }
    #     end
    #   end
      
      categories << category_data
    #   Add child categories to the main array as well
    #   categories.concat(category_data['children']) if category_data['children']
    end
    
    # Sort the final array by order
    categories = categories.sort_by { |category| category['order'] }
    
    Rails.logger.info "Parsed #{categories.size} store categories"
    categories
  end

  def update_store_categories(new_categories)
    # Get the new category IDs
    new_category_ids = new_categories.map { |c| c['id'] }
    
    # Get the existing category IDs
    existing_category_ids = @ebay_account.store_categories.map { |c| c['id'] }
    
    # Find categories that no longer exist
    removed_category_ids = existing_category_ids - new_category_ids
    
    if removed_category_ids.any?
      # Remove tag mappings for deleted categories
      removed_category_ids.each do |category_id|
        @ebay_account.category_tag_mappings.delete(category_id)
      end
      Rails.logger.info "Removed #{removed_category_ids.size} obsolete store categories"
    end

    # Update the store categories and clean up tag mappings
    @ebay_account.update(
      store_categories: new_categories,
      category_tag_mappings: @ebay_account.category_tag_mappings.slice(*new_category_ids)
    )
  end
end 