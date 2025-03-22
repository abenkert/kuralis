class ImportEbayListingsJob < ApplicationJob
  queue_as :default

  ENTRIES_PER_PAGE = 200
  MAX_TIME_RANGE_DAYS = 120 # eBay's max time range for GetSellerList API

  def perform(shop_id, last_sync_time = nil)
    shop = Shop.find(shop_id)
    ebay_account = shop.shopify_ebay_account
    return unless ebay_account

    # Track existing listings before import
    existing_item_ids = ebay_account.ebay_listings.pluck(:ebay_item_id)
    processed_item_ids = []

    token_service = EbayTokenService.new(shop)

    # If no specific sync time is provided, get all listings in 120-day chunks
    if last_sync_time.nil?
      # Start with current date and move backwards
      end_time = Time.current

      # Find the seller's oldest active listing date instead of using arbitrary cutoff
      oldest_date = fetch_oldest_listing_date(token_service) || 5.years.ago
      Rails.logger.info("Using oldest listing date: #{oldest_date}")

      # Process one time chunk at a time until we reach the oldest date
      while end_time > oldest_date
        start_time = [ end_time - MAX_TIME_RANGE_DAYS.days, oldest_date ].max
        process_time_period(token_service, ebay_account, start_time, end_time, processed_item_ids)

        # Move to next time period
        end_time = start_time
      end
    else
      # If last_sync_time is provided, just get listings from that time to now
      process_time_period(token_service, ebay_account, last_sync_time, Time.current, processed_item_ids)
    end

    # Update import timestamp
    ebay_account.update(last_listing_import_at: Time.current)
  rescue => e
    Rails.logger.error("Error in ImportEbayListingsJob: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
  end

  # private

  def process_time_period(token_service, ebay_account, start_time, end_time, processed_item_ids)
    page = 1
    has_more_pages = true

    Rails.logger.info("Processing eBay listings from #{start_time} to #{end_time}")

    while has_more_pages
      begin
        token = token_service.fetch_or_refresh_access_token
        response = fetch_seller_listings(token, page, start_time, end_time)
        namespaces = { "ns" => "urn:ebay:apis:eBLBaseComponents" }

        if response&.at_xpath("//ns:Ack", namespaces)&.text == "Success"
          items = response.xpath("//ns:Item", namespaces)

          # If no items found in this page, we're done with this time period
          if items.empty?
            has_more_pages = false
          else
            processed_item_ids += process_items(items, ebay_account)

            # Check if there are more pages
            total_pages = response.at_xpath("//ns:PaginationResult/ns:TotalNumberOfPages", namespaces)&.text.to_i || 0
            total_entries = response.at_xpath("//ns:PaginationResult/ns:TotalNumberOfEntries", namespaces)&.text.to_i || 0

            Rails.logger.info("Processed page #{page} of #{total_pages} (#{items.size} listings, total entries: #{total_entries})")

            has_more_pages = page < total_pages
            page += 1 if has_more_pages
          end
        else
          error_message = response&.at_xpath("//ns:Errors/ns:ShortMessage", namespaces)&.text || "Unknown error"
          Rails.logger.error("eBay API error: #{error_message}")
          has_more_pages = false
        end
      rescue => e
        Rails.logger.error("Error processing eBay listings page #{page}: #{e.message}")
        has_more_pages = false
      end
    end
  end

  def process_items(items, ebay_account)
    processed_ids = []
    namespaces = { "ns" => "urn:ebay:apis:eBLBaseComponents" }

    items.each do |item|
      begin
        ebay_item_id = item.at_xpath(".//ns:ItemID", namespaces).text
        processed_ids << ebay_item_id

        listing = ebay_account.ebay_listings.find_or_initialize_by(ebay_item_id: ebay_item_id)
        description = prepare_description(item.at_xpath(".//ns:Description", namespaces)&.text)
        location = find_location(description)
        # Update attributes regardless of whether it's a new or existing record
        listing.assign_attributes({
          title: item.at_xpath(".//ns:Title", namespaces)&.text,
          description: description,
          sale_price: item.at_xpath(".//ns:SellingStatus/ns:CurrentPrice", namespaces)&.text&.to_d,
          original_price: item.at_xpath(".//ns:StartPrice", namespaces)&.text&.to_d,
          quantity: item.at_xpath(".//ns:Quantity", namespaces)&.text&.to_i,
          shipping_profile_id: item.at_xpath(".//ns:SellerProfiles/ns:SellerShippingProfile/ns:ShippingProfileID", namespaces)&.text,
          location: location,
          image_urls: extract_image_urls(item, namespaces),
          listing_format: item.at_xpath(".//ns:ListingType", namespaces)&.text,
          condition_id: item.at_xpath(".//ns:ConditionID", namespaces)&.text,
          condition_description: item.at_xpath(".//ns:ConditionDisplayName", namespaces)&.text,
          category_id: item.at_xpath(".//ns:PrimaryCategory/ns:CategoryID", namespaces)&.text,
          store_category_id: item.at_xpath(".//ns:Storefront/ns:StoreCategoryID", namespaces)&.text,
          listing_duration: item.at_xpath(".//ns:ListingDuration", namespaces)&.text,
          end_time: Time.parse(item.at_xpath(".//ns:ListingDetails/ns:EndTime", namespaces)&.text.to_s),
          best_offer_enabled: item.at_xpath(".//ns:BestOfferDetails/ns:BestOfferEnabled", namespaces)&.text == "true",
          ebay_status: item.at_xpath(".//ns:SellingStatus/ns:ListingStatus", namespaces)&.text&.downcase,
          last_sync_at: Time.current
        })

        if listing.changed?
          Rails.logger.info("Changes detected for #{ebay_item_id}: #{listing.changes.inspect}")
          if listing.save
            Rails.logger.info("#{listing.new_record? ? 'Created' : 'Updated'} listing #{ebay_item_id}")
            listing.cache_images unless listing.images.attached?
          else
            Rails.logger.error("Failed to save listing #{ebay_item_id}: #{listing.errors.full_messages.join(', ')}")
          end
        else
          Rails.logger.info("No changes detected for listing #{ebay_item_id}")
        end
      rescue => e
        Rails.logger.error("Error processing item: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))
      end
    end

    processed_ids
  end

  def prepare_description(description)
    CGI.unescapeHTML(description)
  end

  def find_location(description)
    doc = Nokogiri::HTML(description)
    potential_code = doc.at_css("div font")&.text
    if potential_code&.match?(/\A[OW]\d+.*\z/)
      location_code = potential_code
    else
      location_code = nil
    end
    location_code
  end

  def extract_image_urls(item, namespaces)
    urls = []
    picture_details = item.at_xpath(".//ns:PictureDetails", namespaces)
    if picture_details
      # Get all PictureURL elements, not just the first one
      picture_details.xpath(".//ns:PictureURL", namespaces).each do |pic_url|
        urls << pic_url.text if pic_url.text.present?
      end
    end
    urls.compact
  end

  def fetch_seller_listings(access_token, page_number, start_time_from = nil, start_time_to = nil)
    uri = URI("https://api.ebay.com/ws/api.dll")

    # If no time range is provided, default to last 120 days (eBay's maximum)
    start_time_from ||= 120.days.ago
    start_time_to ||= Time.current

    xml_request = <<~XML
      <?xml version="1.0" encoding="utf-8"?>
      <GetSellerListRequest xmlns="urn:ebay:apis:eBLBaseComponents">
        <DetailLevel>ReturnAll</DetailLevel>
        <StartTimeFrom>#{start_time_from.iso8601}</StartTimeFrom>
        <StartTimeTo>#{start_time_to.iso8601}</StartTimeTo>
        <Pagination>
          <EntriesPerPage>#{ENTRIES_PER_PAGE}</EntriesPerPage>
          <PageNumber>#{page_number}</PageNumber>
        </Pagination>
      </GetSellerListRequest>
    XML

    headers = {
      "X-EBAY-API-COMPATIBILITY-LEVEL" => "967",
      "X-EBAY-API-IAF-TOKEN" => access_token,
      "X-EBAY-API-DEV-NAME" => ENV["EBAY_DEV_ID"],
      "X-EBAY-API-APP-NAME" => ENV["EBAY_CLIENT_ID"],
      "X-EBAY-API-CERT-NAME" => ENV["EBAY_CLIENT_SECRET"],
      "X-EBAY-API-CALL-NAME" => "GetSellerList",
      "X-EBAY-API-SITEID" => "0",
      "Content-Type" => "text/xml"
    }

    begin
      response = Net::HTTP.post(uri, xml_request, headers)
      Rails.logger.info("eBay API response status: #{response.code}")

      Nokogiri::XML(response.body)
    rescue StandardError => e
      Rails.logger.error("Error fetching seller listings: #{e.message}")
      nil
    end
  end

  # Find the seller's oldest active listing date
  def fetch_oldest_listing_date(token_service)
    token = token_service.fetch_or_refresh_access_token
    uri = URI("https://api.ebay.com/ws/api.dll")

    xml_request = <<~XML
      <?xml version="1.0" encoding="utf-8"?>
      <GetMyeBaySellingRequest xmlns="urn:ebay:apis:eBLBaseComponents">
        <ActiveList>
          <Sort>StartTime</Sort>
          <Pagination>
            <EntriesPerPage>1</EntriesPerPage>
            <PageNumber>1</PageNumber>
          </Pagination>
        </ActiveList>
      </GetMyeBaySellingRequest>
    XML

    headers = {
      "X-EBAY-API-COMPATIBILITY-LEVEL" => "967",
      "X-EBAY-API-IAF-TOKEN" => token,
      "X-EBAY-API-DEV-NAME" => ENV["EBAY_DEV_ID"],
      "X-EBAY-API-APP-NAME" => ENV["EBAY_CLIENT_ID"],
      "X-EBAY-API-CERT-NAME" => ENV["EBAY_CLIENT_SECRET"],
      "X-EBAY-API-CALL-NAME" => "GetMyeBaySelling",
      "X-EBAY-API-SITEID" => "0",
      "Content-Type" => "text/xml"
    }

    begin
      response = Net::HTTP.post(uri, xml_request, headers)
      Rails.logger.info("eBay GetMyeBaySelling API response status: #{response.code}")

      if response.code.to_i == 200
        doc = Nokogiri::XML(response.body)
        namespaces = { "ns" => "urn:ebay:apis:eBLBaseComponents" }

        # Try to extract start time from the oldest item
        start_time_node = doc.at_xpath("//ns:ActiveList/ns:ItemArray/ns:Item/ns:ListingDetails/ns:StartTime", namespaces)
        if start_time_node && start_time_node.text.present?
          return Time.parse(start_time_node.text.to_s)
        end
      end
    rescue => e
      Rails.logger.error("Error fetching oldest listing date: #{e.message}")
    end

    # Fall back to 3 years if we couldn't determine oldest listing
    Rails.logger.info("Could not determine oldest listing date, falling back to 3 years ago")
    3.years.ago
  end
end
