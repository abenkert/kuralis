class SettingsController < AuthenticatedController
  layout "authenticated"

  def index
    @shop = current_shop
    @ebay_account_linked = @shop&.shopify_ebay_account.present?
    @warehouses = @shop.warehouses.order(is_default: :desc, name: :asc)
  end

  def sync_locations
    @shop = current_shop
    locations_query = <<~GQL
      {
        locations(first: 10) {
          edges {
            node {
              id
              name
            }
          }
        }
      }
    GQL

    client = ShopifyAPI::Clients::Graphql::Admin.new(session: @shop.shopify_session)
    response = client.query(query: locations_query)

    if response.body["data"] && response.body["data"]["locations"]
      locations = response.body["data"]["locations"]["edges"].each_with_object({}) do |edge, hash|
        node = edge["node"]
        hash[node["id"]] = {
          "name" => node["name"],
          "active" => node["active"]
        }
      end

      @shop.update!(locations: locations)

      # Set default location if none set and locations exist
      if @shop.default_location_id.blank? && locations.any?
        @shop.update(default_location_id: locations.keys.first)
      end

      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to settings_path, notice: "Locations synchronized successfully" }
      end
    else
      error_message = "Failed to fetch locations: #{response.body['errors']&.inspect}"
      Rails.logger.error error_message

      respond_to do |format|
        format.turbo_stream {
          render turbo_stream: [
            turbo_stream.replace("locations_form", partial: "settings/locations_form", locals: { shop: @shop }),
            turbo_stream.prepend("flash", partial: "shared/flash", locals: { flash: { error: error_message } })
          ]
        }
        format.html { redirect_to settings_path, alert: error_message }
      end
    end
  rescue => e
    error_message = "Error syncing locations: #{e.message}"
    Rails.logger.error error_message
    Rails.logger.error e.backtrace.join("\n")

    respond_to do |format|
      format.turbo_stream {
        render turbo_stream: [
          turbo_stream.replace("locations_form", partial: "settings/locations_form", locals: { shop: @shop }),
          turbo_stream.prepend("flash", partial: "shared/flash", locals: { flash: { error: error_message } })
        ]
      }
      format.html { redirect_to settings_path, alert: error_message }
    end
  end

  def update_default_location
    @shop = current_shop
    if @shop.update(default_location_params)
      respond_to do |format|
        format.turbo_stream {
          render turbo_stream: turbo_stream.replace(
            "locations_form",
            partial: "settings/locations_form",
            locals: { shop: @shop }
          )
        }
        format.html { redirect_to settings_path, notice: "Default location updated" }
      end
    else
      respond_to do |format|
        format.turbo_stream {
          render turbo_stream: turbo_stream.replace(
            "locations_form",
            partial: "settings/locations_form",
            locals: { shop: @shop }
          )
        }
        format.html { redirect_to settings_path, alert: "Failed to update default location" }
      end
    end
  end

  private

  def default_location_params
    params.require(:shop).permit(:default_location_id)
  end
end
