require "net/http"
require "uri"
require "json"
require "tempfile"
require "net/http/post/multipart"

module Shopify
  class StagedUploadService
    def initialize(shop)
      @shop = shop
      @client = ShopifyAPI::Clients::Graphql::Admin.new(session: @shop.shopify_session)
    end

    def upload_image(image)
      file = image.download
      filename = image.filename.to_s
      mime_type = image.content_type

      # Step 1: Get staged upload target
      query = <<~GRAPHQL
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
      GRAPHQL

      variables = {
        input: [
          {
            filename: filename,
            mimeType: mime_type,
            resource: "IMAGE",
            httpMethod: "POST",
            fileSize: file.size.to_s
          }
        ]
      }

      response = @client.query(query: query, variables: variables)
      target = response.body.dig("data", "stagedUploadsCreate", "stagedTargets")&.first
      raise "Failed to get staged upload target: #{response.body}" unless target

      # Step 2: Upload to S3
      url = target["url"]
      params = target["parameters"].map { |p| [ p["name"], p["value"] ] }.to_h

      Tempfile.create(filename) do |tempfile|
        tempfile.binmode
        tempfile.write(file)
        tempfile.rewind

        # Prepare multipart params
        multipart_params = params.transform_values { |v| v }
        multipart_params["file"] = UploadIO.new(tempfile, mime_type, filename)

        uri = URI.parse(url)
        request = Net::HTTP::Post::Multipart.new(uri, multipart_params)

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        upload_response = http.request(request)
        unless upload_response.is_a?(Net::HTTPSuccess) || upload_response.code.to_i == 204
          raise "Failed to upload image to Shopify S3: #{upload_response.body}"
        end
      end

      # Step 3: Return the resourceUrl for use in product/media mutation
      target["resourceUrl"]
    end
  end
end
