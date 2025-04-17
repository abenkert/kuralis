class FetchEbayOrdersJob < ApplicationJob
  queue_as :default

  def perform(shop_id)
    shop = Shop.find(shop_id)
    token = EbayTokenService.new(shop).fetch_or_refresh_access_token
    
    # Fetch recent active orders
    start_time = 48.hours.ago.iso8601
    
    uri = URI('https://api.ebay.com/ws/api.dll')
    xml_request = build_get_orders_request(token, start_time)
    
    headers = {
      'X-EBAY-API-COMPATIBILITY-LEVEL' => '967',
      'X-EBAY-API-IAF-TOKEN' => token,
      'X-EBAY-API-CALL-NAME' => 'GetOrders',
      'X-EBAY-API-SITEID' => '0',
      'Content-Type' => 'text/xml'
    }

    response = Net::HTTP.post(uri, xml_request, headers)
    
    if response.is_a?(Net::HTTPSuccess)
      active_order_ids = process_orders_response(response.body, shop)
      mark_completed_orders(shop, active_order_ids, start_time)
    end
  end

  private

  def build_get_orders_request(token, start_time)
    <<~XML
      <?xml version="1.0" encoding="utf-8"?>
      <GetOrdersRequest xmlns="urn:ebay:apis:eBLBaseComponents">
        <RequesterCredentials>
          <eBayAuthToken>#{token}</eBayAuthToken>
        </RequesterCredentials>
        <CreateTimeFrom>#{start_time}</CreateTimeFrom>
        <OrderRole>Seller</OrderRole>
        <OrderStatus>Active</OrderStatus>
        <OrderStatus>Completed</OrderStatus>
        <ListingType>FixedPriceItem</ListingType>
        <DetailLevel>ReturnAll</DetailLevel>
        <Pagination>
          <EntriesPerPage>100</EntriesPerPage>
          <PageNumber>1</PageNumber>
        </Pagination>
        <Version>967</Version>
      </GetOrdersRequest>
    XML
  end

  def process_orders_response(response_xml, shop)
    doc = Nokogiri::XML(response_xml)
    doc.remove_namespaces!
    
    active_order_ids = []
    
    orders = doc.xpath('//Order')
    orders.each do |order_xml|
      # Skip orders that don't have transactions
      next unless order_xml.at_xpath('.//TransactionArray/Transaction')
      
      order = create_or_update_order(order_xml, shop)
      active_order_ids << order.platform_order_id if order.present?
      process_order_items(order, order_xml) if order.present?
    end

    active_order_ids
  end

  def mark_completed_orders(shop, active_order_ids, start_time)
    # Find orders that were created after start_time but aren't in the active list
    shop.orders
        .where(platform: 'ebay')
        .where('created_at > ?', start_time)
        .where.not(platform_order_id: active_order_ids)
        .where.not(status: 'completed')
        .update_all(
          status: 'completed',
          updated_at: Time.current
        )
  end

  def create_or_update_order(order_xml, shop)
    order_id = order_xml.at_xpath('.//OrderID')&.text
    ebay_status = order_xml.at_xpath('.//OrderStatus')&.text
    
    order = Order.find_or_initialize_by(
      platform: 'ebay',
      platform_order_id: order_id,
      shop_id: shop.id
    )

    buyer_node = order_xml.at_xpath('.//TransactionArray/Transaction/Buyer')
    buyer_name = if buyer_node
      first_name = buyer_node.at_xpath('.//UserFirstName')&.text
      last_name = buyer_node.at_xpath('.//UserLastName')&.text
      "#{first_name} #{last_name}".strip
    end

    order.assign_attributes({
      status: map_ebay_status(ebay_status),
      total_price: order_xml.at_xpath('.//Total')&.text&.to_d,
      subtotal: order_xml.at_xpath('.//Subtotal')&.text&.to_d,
      shipping_cost: order_xml.at_xpath('.//ShippingServiceSelected/ShippingServiceCost')&.text&.to_d,
      payment_status: order_xml.at_xpath('.//CheckoutStatus/Status')&.text,
      shipping_address: extract_shipping_address(order_xml),
      customer_name: buyer_name,
      order_placed_at: order_xml.at_xpath('.//CreatedTime')&.text
    })

    order.save!
    order
  end

  def extract_shipping_address(order_xml)
    address = order_xml.at_xpath('.//ShippingAddress')
    return {} unless address

    {
      name: address.at_xpath('.//Name')&.text,
      street1: address.at_xpath('.//Street1')&.text,
      street2: address.at_xpath('.//Street2')&.text,
      city: address.at_xpath('.//CityName')&.text,
      state: address.at_xpath('.//StateOrProvince')&.text,
      postal_code: address.at_xpath('.//PostalCode')&.text,
      country: address.at_xpath('.//CountryName')&.text,
      phone: address.at_xpath('.//Phone')&.text
    }
  end

  def process_order_items(order, order_xml)
    transactions = order_xml.xpath('.//TransactionArray/Transaction')
    
    transactions.each do |transaction|
      item_data = extract_item_data(transaction)
      create_or_update_order_item(order, item_data)
    end
  end

  def extract_item_data(transaction)
    {
      platform_item_id: transaction.at_xpath('.//Item/ItemID')&.text,
      title: transaction.at_xpath('.//Item/Title')&.text,
      quantity: transaction.at_xpath('.//QuantityPurchased')&.text&.to_i,
      platform_transaction_id: transaction.at_xpath('.//TransactionID')&.text,
      created_at: transaction.at_xpath('.//CreatedDate')&.text
    }
  end

  def create_or_update_order_item(order, item_data)
    order_item = order.order_items.find_or_initialize_by(
      platform_item_id: item_data[:platform_item_id],
      platform: 'ebay'
    )
    # We need to implement a call here possibly to get the location of the item?
    order_item.assign_attributes(
      title: item_data[:title],
      quantity: item_data[:quantity],
    )

    order_item.save!
    order_item
  end

  def map_ebay_status(ebay_status)
    case ebay_status
    when 'Active' then 'pending'
    when 'Completed' then 'completed'
    when 'Shipped' then 'shipped'
    else 'pending'
    end
  end
end 