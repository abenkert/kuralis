class DashboardController < AuthenticatedController
  layout "authenticated"

  def index
    @shop = current_shop
  end
end
