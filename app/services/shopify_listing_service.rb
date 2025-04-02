class ShopifyListingService
  def initialize(kuralis_product)
    @product = kuralis_product
    @shop = @product.shop
    @client = ShopifyAPI::Clients::Graphql::Admin.new(session: @shop.shopify_session)
  end

  def create_listing
    # We currently do not support multiple variants
    return false if @product.shopify_product.present?

    product_variables = {
        "synchronous": true,
        "productSet": {
          "title": @product.title,
          "descriptionHtml": escape_html(@product.description),
          "tags": @product.tags,
          "files": prepare_product_images,
          "productOptions": [
            {
              "name": "Title",
              "position": 1,
              "values": [
                {
                  "name": "Default Title"
                }
              ]
            }
          ],
          "variants": [
            {
              "optionValues": [
                {
                  "optionName": "Title",
                  "name": "Default Title"
                }
              ],
              "inventoryItem": {
                "tracked": true,
                "measurement": {
                  "weight": {
                    "unit": "OUNCES",
                    "value": @product.weight_oz.to_f
                  }
                }
              },
              "inventoryQuantities": [
                {
                  "locationId": @shop.default_location_id,
                  "name": "available",
                  "quantity": @product.base_quantity
                }
              ],
              "price": @product.base_price
            }
          ]
        }
      }

    product_response = @client.query(
      query: build_create_product_mutation,
      variables: product_variables
    )

    pp product_response

    if product_response && product_response.body["data"] && product_response.body["data"]["productSet"]["product"]
        product_data = product_response.body["data"]["productSet"]["product"]
        variant_data = product_data["variants"]["nodes"].first

        product_id = product_data["id"].split("/").last
        variant_id = variant_data["inventoryItem"]["id"].split("/").last

        shopify_product = @product.create_shopify_product!(
            shop: @shop,
            shopify_product_id: product_id,
            shopify_variant_id: variant_id,
            title: @product.title,
            price: @product.base_price,
            quantity: @product.base_quantity,
            sku: @product.sku,
            status: "active",
            published: true
          )

          # Attach the same images from KuralisProduct
          if @product.images.attached?
            @product.images.each do |image|
              image.blob.open do |tempfile|
                shopify_product.images.attach(
                  io: tempfile,
                  filename: image.filename.to_s,
                  content_type: image.content_type,
                  identify: false  # Skip automatic content type identification
                )
              end
            end
          end
    else
        Rails.logger.error "Error creating Shopify product: #{product_response.body['errors']}"
        false
    end
    true
  rescue => e
    Rails.logger.error "Error creating Shopify product: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    false
  end

  private

  def build_create_product_mutation
    # language=GraphQL
    <<~GQL
      mutation createProduct($productSet: ProductSetInput!, $synchronous: Boolean!) {
        productSet(synchronous: $synchronous, input: $productSet) {
          product {
            id
            variants(first: 1) {
              nodes {
                title
                price
                inventoryQuantity
                inventoryItem {
                  id
                }
              }
            }
            media(first: 1) {
              edges {
                node {
                  preview {
                    status#{'    '}
                    image {
                        id
                        url
                    }
                  }
                }
              }
            }
          }
        userErrors {
              field
              message
            }
        }
      }
    GQL
  end

  def generate_image_url(image)
    if Rails.env.production?
      Rails.application.routes.url_helpers.url_for(image)
    else
      image.blob.url(expires_in: 1.hour)
    end
  end

  def prepare_product_images
    @product.images.map do |image|
      {
        "contentType": "IMAGE",
        "alt": @product.title,
        "originalSource": generate_image_url(image)
      }
    end
  end

  def escape_html(text)
    return "" unless text
    text.gsub('"', '\"').gsub("\n", '\n').gsub("\r", "")
  end
end
