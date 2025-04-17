class FetchShopifyOrdersJob < ApplicationJob
  queue_as :default

  def perform(shop_id)
    shop = Shop.find(shop_id)
    
    cursor = nil
    active_order_ids = []
    client = ShopifyAPI::Clients::Graphql::Admin.new(session: shop.shopify_session)
    
    loop do
      orders_query = build_orders_query(cursor)
      response = client.query(query: orders_query)
      result = response.body["data"]
      break unless result && result["orders"]
      
      orders = result["orders"]["edges"]
      break if orders.empty?
      pp orders
      
      orders.each do |edge|
        order = edge["node"]
        shopify_order = create_or_update_order(OpenStruct.new(order), shop)
        active_order_ids << shopify_order.platform_order_id if shopify_order.present?
      end
      
      cursor = orders.last["cursor"]
      break unless result["orders"]["pageInfo"]["hasNextPage"]
    end

    mark_completed_orders(shop, active_order_ids)
  end

  private

  def create_or_update_order(order_data, shop)
    order = Order.find_or_initialize_by(
      platform: 'shopify',
      platform_order_id: order_data.id.split('/').last,
      shop_id: shop.id
    )

    order.assign_attributes({
      status: map_shopify_status(order_data.displayFulfillmentStatus || order_data.displayFinancialStatus),
      total_price: order_data.totalPriceSet["shopMoney"]["amount"].to_f,
      subtotal: order_data.subtotalPriceSet["shopMoney"]["amount"].to_f,
      shipping_cost: order_data.totalShippingPriceSet["shopMoney"]["amount"].to_f,
      payment_status: order_data.displayFinancialStatus,
      shipping_address: extract_shipping_address(order_data.shippingAddress),
      customer_name: extract_customer_name(order_data.customer),
      order_placed_at: order_data.createdAt
    })

    order.save!
    process_order_items(order, order_data.lineItems["edges"])
    order
  end

  def process_order_items(order, line_items)
    line_items.each do |edge|
      item = edge["node"]
      order_item = order.order_items.find_or_initialize_by(
        platform: 'shopify',
        platform_item_id: item["variant"]["id"].split('/').last
      )

      order_item.assign_attributes(
        title: item["title"],
        quantity: item["quantity"],
        sku: item["variant"]["sku"]
      )

      order_item.save!
    end
  end

  def extract_customer_name(customer)
    return nil unless customer && customer["firstName"] && customer["lastName"]
    "#{customer["firstName"]} #{customer["lastName"]}".strip
  end

  def extract_shipping_address(address)
    # TODO: Request customer permission for address and name
    return nil 
    {
      name: address["name"],
      street1: address["address1"],
      street2: address["address2"],
      city: address["city"],
      state: address["province"],
      postal_code: address["zip"],
      country: address["country"],
      phone: address["phone"]
    }
  end

  def map_shopify_status(status)
    case status
    when 'UNFULFILLED' then 'pending'
    when 'FULFILLED' then 'completed'
    when 'PARTIALLY_FULFILLED' then 'partial'
    else 'pending'
    end
  end

  def mark_completed_orders(shop, active_order_ids)
    shop.orders
        .where(platform: 'shopify')
        .where('created_at > ?', 48.hours.ago)
        .where.not(platform_order_id: active_order_ids)
        .where.not(status: 'completed')
        .update_all(
          status: 'completed',
          updated_at: Time.current
        )
  end

  def build_orders_query(cursor)
    after_param = cursor ? ", after: \"#{cursor}\"" : ""
    <<~GQL
      {
        orders(first: 50#{after_param}, query: "created_at:>=#{48.hours.ago.iso8601}") {
          edges {
            cursor
            node {
              id
              name
              createdAt
              displayFulfillmentStatus
              displayFinancialStatus
              totalPriceSet {
                shopMoney {
                  amount
                }
              }
              subtotalPriceSet {
                shopMoney {
                  amount
                }
              }
              totalShippingPriceSet {
                shopMoney {
                  amount
                }
              }
              customer {
                firstName
                lastName
              }
              shippingAddress {
                name
                address1
                address2
                city
                province
                zip
                country
                phone
              }
              lineItems(first: 50) {
                edges {
                  node {
                    title
                    quantity
                    variant {
                      id
                      sku
                    }
                  }
                }
              }
            }
          }
          pageInfo {
            hasNextPage
          }
        }
      }
    GQL
  end
end 