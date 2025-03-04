module Kuralis
  class Collector

    attr_reader :products

    def initialize(shop_id, params)
      @shop = Shop.find(shop_id)
      @params = params
    end

    def gather_data
        @products = @shop.kuralis_products
                    .order(created_at: :desc)
                    .then { |query| apply_filter(query) }
                    .page(@params[:page])
                    .per(25)

        self
    end

    def active_on_ebay?(product)
        yield if product.ebay_listing.present? && product.ebay_listing.active?
    end

    def active_on_shopify?(product)
        yield if product.shopify_product.present? && product.shopify_product.active?
    end

    def not_active_on_ebay?(product)
        yield if !product.ebay_listing.present? || !product.ebay_listing.active?
    end

    def not_active_on_shopify?(product)
        yield if !product.shopify_product.present? || !product.shopify_product.active?
    end

    def apply_filter(query)
        case @filter
        when 'unlisted'
          query.where(shopify_product_id: nil, ebay_listing_id: nil)
        when 'shopify'
          query.where.not(shopify_product_id: nil)
        when 'ebay'
          query.where.not(ebay_listing_id: nil)
        else
          query
        end
      end

  end
end