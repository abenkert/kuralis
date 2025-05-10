

def test_staged_upload
  shop = Shop.first
  client = ShopifyAPI::Clients::Graphql::Admin.new(session: shop.shopify_session)

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

  variables = {
    input: [ {
      resource: "PRODUCT_IMAGE",
      filename: "test_image.jpg",
      mimeType: "image/jpeg",
      httpMethod: "POST"
    } ]
  }

  response = client.query(
    query: mutation,
    variables: variables
  )

  puts "\nStaged Upload Response:"
  puts JSON.pretty_generate(response.body)

  if response.body["extensions"]&.dig("cost")
    puts "\nQuery Cost:"
    puts JSON.pretty_generate(response.body["extensions"]["cost"])
  end
end

puts "Test methods loaded! Run one of these:"
puts "- test_staged_upload     # Basic test with default settings (BulkListingJob)"
