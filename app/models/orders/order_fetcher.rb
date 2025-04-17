module Orders
  class OrderFetcher
    attr_reader :shop, :tab

    def initialize(shop, tab = 'all')
      @shop = shop
      @tab = tab
    end

    def fetch
      apply_filters(base_query)
    end

    private

    def base_query
      shop.orders
          .includes(:order_items)
          .order(created_at: :desc)
    end

    def apply_filters(query)
      case tab
      when 'pending'
        query.where(status: 'pending')
      when 'paid'
        query.where(status: 'completed', payment_status: 'paid')
      when 'shipped'
        query.where(status: 'shipped')
      when 'completed'
        query.where(status: 'completed')
      else
        query
      end
    end
  end
end 