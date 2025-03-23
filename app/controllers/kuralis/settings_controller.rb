class Kuralis::SettingsController < AuthenticatedController
  def update
    @shop = current_shop

    params[:settings]&.each do |category, settings|
      settings.each do |key, value|
        @shop.set_setting(category, key, value)
      end
    end

    respond_to do |format|
      format.turbo_stream {
        render turbo_stream: [
          turbo_stream.replace("settings_form", partial: "kuralis/settings/form", locals: { shop: @shop }),
          turbo_stream.prepend("flash", partial: "shared/flash", locals: { flash: { notice: "Settings updated successfully" } })
        ]
      }
      format.html { redirect_to settings_path, notice: "Settings updated successfully" }
    end
  end
end
