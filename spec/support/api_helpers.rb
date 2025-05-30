# API testing helpers for external integrations
module ApiHelpers
  # eBay API mocking
  def stub_ebay_get_item_request(item_id, response_data = {})
    default_response = {
      "Item" => {
        "ItemID" => item_id,
        "Title" => "Test Product",
        "Quantity" => 5,
        "StartPrice" => "19.99"
      }
    }

    stub_request(:post, /.*sandbox\.ebay\.com.*/)
      .with(body: /GetItem/)
      .to_return(
        status: 200,
        body: build_ebay_response(default_response.merge(response_data)),
        headers: { 'Content-Type' => 'text/xml' }
      )
  end

  def stub_ebay_revise_item_request(item_id, success: true)
    response_data = if success
      { "ItemID" => item_id, "Ack" => "Success" }
    else
      { "Ack" => "Failure", "Errors" => { "ErrorCode" => "123", "LongMessage" => "Test error" } }
    end

    stub_request(:post, /.*sandbox\.ebay\.com.*/)
      .with(body: /ReviseFixedPriceItem/)
      .to_return(
        status: success ? 200 : 400,
        body: build_ebay_response(response_data),
        headers: { 'Content-Type' => 'text/xml' }
      )
  end

  def stub_ebay_get_orders_request(orders_data = [])
    default_orders = [
      {
        "OrderID" => "123-456-789",
        "OrderStatus" => "Completed",
        "CreatedTime" => 1.day.ago.iso8601,
        "TransactionArray" => {
          "Transaction" => [
            {
              "Item" => { "ItemID" => "123456789" },
              "QuantityPurchased" => 1
            }
          ]
        }
      }
    ]

    stub_request(:post, /.*sandbox\.ebay\.com.*/)
      .with(body: /GetOrders/)
      .to_return(
        status: 200,
        body: build_ebay_response({ "OrderArray" => { "Order" => orders_data.empty? ? default_orders : orders_data } }),
        headers: { 'Content-Type' => 'text/xml' }
      )
  end

  # Shopify API mocking
  def stub_shopify_products_request(products_data = [])
    default_product = {
      "id" => 123456789,
      "title" => "Test Product",
      "variants" => [
        {
          "id" => 987654321,
          "inventory_quantity" => 5,
          "price" => "19.99"
        }
      ]
    }

    stub_request(:get, /.*\.myshopify\.com\/admin\/api\/.*\/products\.json/)
      .to_return(
        status: 200,
        body: { products: products_data.empty? ? [ default_product ] : products_data }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
  end

  def stub_shopify_inventory_update_request(variant_id, success: true)
    if success
      stub_request(:post, /.*\.myshopify\.com\/admin\/api\/.*\/inventory_levels\/adjust\.json/)
        .to_return(
          status: 200,
          body: { inventory_level: { variant_id: variant_id, available: 10 } }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )
    else
      stub_request(:post, /.*\.myshopify\.com\/admin\/api\/.*\/inventory_levels\/adjust\.json/)
        .to_return(
          status: 422,
          body: { errors: "Inventory adjustment failed" }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )
    end
  end

  # OpenAI API mocking
  def stub_openai_chat_request(response_text = "Test AI response")
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(
        status: 200,
        body: {
          choices: [
            {
              message: {
                content: response_text
              }
            }
          ]
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
  end

  def stub_openai_embeddings_request(embeddings = [ 0.1, 0.2, 0.3 ])
    stub_request(:post, "https://api.openai.com/v1/embeddings")
      .to_return(
        status: 200,
        body: {
          data: [
            {
              embedding: embeddings
            }
          ]
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
  end

  private

  def build_ebay_response(data)
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/">
        <soapenv:Body>
          <GetItemResponse xmlns="urn:ebay:apis:eBLBaseComponents">
            #{data.to_xml(root: false, skip_instruct: true)}
          </GetItemResponse>
        </soapenv:Body>
      </soapenv:Envelope>
    XML
  end
end

RSpec.configure do |config|
  config.include ApiHelpers
end
