#!/usr/bin/env ruby
# This file can be loaded in Rails console to test the image upload and product creation flow

class ImageUploadTest
  def initialize(shop_id, product_id)
    @shop = Shop.find(shop_id)
    @product = KuralisProduct.find(product_id)
    @client = ShopifyAPI::Clients::Graphql::Admin.new(session: @shop.shopify_session)
  end

  def run
    # Check if product has attached images
    unless @product.images.attached?
      return puts "No images attached to product #{@product.id}. Please attach images first."
    end

    puts "Starting image upload test with #{@product.images.count} attached images..."
    resource_urls = []

    # Upload each attached image
    @product.images.each do |image|
      puts "Processing image: #{image.filename}"

      # Step 1: Create staged upload for the image
      staged_upload = create_staged_upload(image)
      unless staged_upload
        puts "Failed to create staged upload for image #{image.filename}"
        next
      end

      # Step 2: Upload the image to the staged URL
      resource_url = upload_to_staged_url(staged_upload, image)
      unless resource_url
        puts "Failed to upload image #{image.filename}"
        next
      end

      resource_urls << {
        resource_url: resource_url,
        alt: @product.title
      }
    end

    if resource_urls.empty?
      puts "No images were successfully uploaded. Aborting product creation."
      return
    end

    # Step 3: Use the resource URLs in productSet mutation
    puts "Creating product with #{resource_urls.size} images"
    create_product_with_images(resource_urls)
  end

  private

  def create_staged_upload(image)
    puts "Creating staged upload for #{image.filename}..."

    # Open image blob to get metadata
    image.blob.open do |file|
      # Create the mutation
      mutation = <<~GQL
        mutation stagedUploadsCreate($input: [StagedUploadInput!]!) {
          stagedUploadsCreate(input: $input) {
            stagedTargets {
              url
              resourceUrl
              parameters {
                name
                value
              }
            }
            userErrors {
              field
              message
            }
          }
        }
      GQL

      # Set variables
      variables = {
        input: [
          {
            resource: "IMAGE",
            filename: image.filename.to_s,
            mimeType: image.content_type,
            fileSize: image.byte_size.to_s,
            httpMethod: "POST"
          }
        ]
      }

      # Execute the query
      response = @client.query(query: mutation, variables: variables)

      if response.body["data"] && response.body["data"]["stagedUploadsCreate"] &&
         response.body["data"]["stagedUploadsCreate"]["stagedTargets"] &&
         response.body["data"]["stagedUploadsCreate"]["stagedTargets"].first
        return response.body["data"]["stagedUploadsCreate"]["stagedTargets"].first
      else
        puts "Error creating staged upload: #{response.body["errors"] || response.body["data"]["stagedUploadsCreate"]["userErrors"]}"
        return nil
      end
    end
  rescue => e
    puts "Error creating staged upload: #{e.message}"
    nil
  end

  def upload_to_staged_url(staged_target, image)
    puts "Uploading image to staged URL..."

    url = staged_target["url"]

    # Convert parameters array to hash
    params = staged_target["parameters"].each_with_object({}) do |param, hash|
      hash[param["name"]] = param["value"]
    end

    # Upload the image using the blob directly
    image.blob.open do |file|
      begin
        response = HTTParty.post(
          url,
          multipart: true,
          body: params.merge("file" => file)
        )

        if response.success?
          puts "Upload successful!"
          return staged_target["resourceUrl"]
        else
          puts "Failed to upload image: #{response.code} - #{response.body}"
          return nil
        end
      rescue => e
        puts "Error uploading image: #{e.message}"
        return nil
      end
    end
  end

  def create_product_with_images(resource_urls)
    puts "Creating product with #{resource_urls.size} images..."

    mutation = <<~GQL
      mutation productSet($input: ProductSetInput!, $synchronous: Boolean!) {
        productSet(input: $input, synchronous: $synchronous) {
          product {
            id
            title
            handle
            media(first: 10) {
              edges {
                node {
                  ... on MediaImage {
                    id
                    image {
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

    variables = {
      synchronous: true,
      input: {
        title: @product.title,
        descriptionHtml: @product.description,
        productOptions: [
          {
            name: "Title",
            values: [ { name: "Default Title" } ]
          }
        ],
        variants: [
          {
            optionValues: [
              { optionName: "Title", name: "Default Title" }
            ],
            price: @product.base_price.to_s,
            inventoryQuantities: [
              {
                locationId: @shop.default_location_id,
                name: "available",
                quantity: @product.base_quantity
              }
            ]
          }
        ],
        files: resource_urls.map do |image_data|
          {
            originalSource: image_data[:resource_url],
            alt: image_data[:alt]
          }
        end
      }
    }

    response = @client.query(query: mutation, variables: variables)
    puts "Product creation response: #{response.body}"

    if response.body["data"] && response.body["data"]["productSet"] && response.body["data"]["productSet"]["product"]
      product = response.body["data"]["productSet"]["product"]
      puts "Successfully created product: #{product["id"]}"

      # Print details about uploaded images
      media_edges = product.dig("media", "edges") || []
      if media_edges.any?
        puts "Images uploaded:"
        media_edges.each_with_index do |edge, idx|
          puts "  #{idx+1}. #{edge.dig('node', 'image', 'url')}"
        end
      else
        puts "Warning: No images were attached to the product on Shopify"
      end

      product
    else
      puts "Error creating product: #{response.body["errors"] || response.body["data"]["productSet"]["userErrors"]}"
      nil
    end
  end
end

# Usage example:
#
# In Rails console:
# load 'test_image_upload.rb'
#
# Then run:
# ImageUploadTest.new(shop_id, product_id).run
#
# For example:
# ImageUploadTest.new(1, 100).run
