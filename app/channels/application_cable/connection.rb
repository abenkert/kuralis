module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_shop

    def connect
      self.current_shop = find_verified_shop
    end

    private

    def find_verified_shop
      # Find the shop based on the session or cookie
      if (session_id = cookies.encrypted[:shopify_session_id])
        Shop.find_by(shopify_domain: ShopifyApp::SessionRepository.retrieve_shop_session_by_id(session_id)&.domain)
      else
        reject_unauthorized_connection
      end
    rescue
      reject_unauthorized_connection
    end
  end
end 