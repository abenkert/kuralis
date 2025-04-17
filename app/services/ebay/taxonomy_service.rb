module Ebay
  class TaxonomyService
    def initialize(ebay_account)
      @ebay_account = ebay_account
      @shop = ebay_account.shop
      @token_service = EbayTokenService.new(@shop)
    end
    
    def fetch_item_aspects(category_id)
      token = @token_service.fetch_or_refresh_access_token
      
      # The Taxonomy API uses a different endpoint and requires a category tree ID
      # For US marketplace, the category tree ID is typically 0
      uri = URI("https://api.ebay.com/commerce/taxonomy/v1/category_tree/0/get_item_aspects_for_category?category_id=#{category_id}")
      
      headers = {
        'Authorization' => "Bearer #{token}",
        'Content-Type' => 'application/json',
        'X-EBAY-C-MARKETPLACE-ID' => 'EBAY_US'
      }
      
      begin
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
          request = Net::HTTP::Get.new(uri, headers)
          http.request(request)
        end
        
        if response.is_a?(Net::HTTPSuccess)
          aspects = JSON.parse(response.body)['aspects'] || []
          
          # Transform the response into our desired format
          aspects.map do |aspect|
            {
              name: aspect['localizedAspectName'],
              required: aspect['aspectConstraint']['aspectRequired'],
              values: aspect['aspectValues']&.map { |v| v['localizedValue'] } || [],
              value_type: determine_value_type(aspect)
            }
          end
        else
          Rails.logger.error "Failed to fetch item aspects: #{response.body}"
          []
        end
      rescue => e
        Rails.logger.error "Error fetching item aspects: #{e.message}"
        []
      end
    end
    
    private
    
    def determine_value_type(aspect)
      # Determine input type based on aspect properties
      if aspect['aspectValues']&.any?
        aspect['aspectConstraint']['aspectMode'] == 'FREE_TEXT' ? 'text_with_suggestions' : 'select'
      else
        'text'
      end
    end
  end
end 