module Shopify
  class ListingService
    def initialize(kuralis_product)
      @product = kuralis_product
      @shop = @product.shop
      @client = ShopifyAPI::Clients::Graphql::Admin.new(session: @shop.shopify_session)
    end

    def create_listing
      return false if @product.shopify_product.present?

      product_variables = {
        "synchronous": true,
        "productSet": {
          "title": @product.title,
          "descriptionHtml": build_item_description,
          "tags": @product.tags,
          "files": prepare_product_images,
          "productOptions": [
            {
              "name": "Title",
              "position": 1,
              "values": [
                { "name": "Default Title" }
              ]
            }
          ],
          "variants": [
            {
              "optionValues": [
                { "optionName": "Title", "name": "Default Title" }
              ],
              "inventoryItem": {
                "tracked": true,
                "measurement": {
                  "weight": { "unit": "OUNCES", "value": @product.weight_oz.to_f }
                }
              },
              "inventoryQuantities": [
                { "locationId": @shop.default_location_id, "name": "available", "quantity": @product.base_quantity }
              ],
              "price": @product.base_price
            }
          ]
        }
      }

      p product_variables

      product_response = @client.query(
        query: build_create_product_mutation,
        variables: product_variables
      )

      p product_response.body

      # If successful, create the ShopifyProduct record
      if product_response.body["data"] && product_response.body["data"]["productSet"] && product_response.body["data"]["productSet"]["product"]
        product_data = product_response.body["data"]["productSet"]["product"]
        variant_data = product_data["variants"]["nodes"].first

        product_id = product_data["id"].split("/").last
        handle = product_data["handle"]
        variant_id = variant_data["inventoryItem"]["id"].split("/").last

        shopify_product = @product.create_shopify_product!(
          shop: @shop,
          shopify_product_id: product_id,
          shopify_variant_id: variant_id,
          handle: handle,
          title: @product.title,
          description: @product.description,
          price: @product.base_price,
          quantity: @product.base_quantity,
          inventory_location: @product.location,
          tags: @product.tags,
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
                identify: false
              )
            end
          end
        end
      end

      product_response # Return the full response for rate limit inspection
    end

    def build_item_description
      description = @product.description
      if @shop.store_location_in_description?
        description = "#{@product.location}\n\n#{description}"
      end

      if @shop.append_description?
        description += "\n\n#{@shop.default_description}"
      end

      description
    end

    private

    def build_create_product_mutation
      # language=GraphQL
      <<~GQL
        mutation createProduct($productSet: ProductSetInput!, $synchronous: Boolean!) {
          productSet(synchronous: $synchronous, input: $productSet) {
            product {
              id
              handle
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
        Rails.logger.info "Generating image URL for #{image.id}"
        Rails.application.routes.url_helpers.url_for(image)
    end

    def prepare_product_images
      staged_upload_service = Shopify::StagedUploadService.new(@shop)
      @product.images.map do |image|
        resource_url = staged_upload_service.upload_image(image)
        {
          "contentType": "IMAGE",
          "alt": @product.title,
          "originalSource": resource_url
        }
      end
    end

    def escape_html(text)
      return "" unless text
      text.gsub('"', '\"').gsub("\n", '\n').gsub("\r", "")
    end
  end
end
