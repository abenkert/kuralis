module Kuralis
  class ProductsController < AuthenticatedController
    layout 'authenticated'

    def index
      @filter = params[:filter] || 'all'
      @products = current_shop.kuralis_products
                            .order(created_at: :desc)
                            .then { |query| apply_filter(query) }
                            .page(params[:page])
                            .per(25)
    end

    def bulk_listing
      @platform = params[:platform]
      @total_count = current_shop.kuralis_products
                            .where(
                              case @platform
                              when 'shopify'
                                { shopify_product_id: nil }
                              when 'ebay'
                                { ebay_listing_id: nil }
                              end
                            ).count
  
      @products = current_shop.kuralis_products
                             .where(
                               case @platform
                               when 'shopify'
                                 { shopify_product_id: nil }
                               when 'ebay'
                                 { ebay_listing_id: nil }
                               end
                             )
                             .order(created_at: :desc)
                             .page(params[:page])
                             .per(100)
    end

    def process_bulk_listing
      platform = params[:platform]
      
      if params[:select_all_records] == '1'
        # Get all product IDs except deselected ones
        deselected_ids = JSON.parse(params[:deselected_ids] || '[]')
        product_ids = current_shop.kuralis_products
                                 .where(
                                   case platform
                                   when 'shopify'
                                     { shopify_product_id: nil }
                                   when 'ebay'
                                     { ebay_listing_id: nil }
                                   end
                                 )
                                 .where.not(id: deselected_ids)
                                 .pluck(:id)
      else
        product_ids = params[:product_ids] || []
      end

      BulkListingJob.perform_later(
        shop_id: current_shop.id,
        product_ids: product_ids,
        platform: platform
      )

      redirect_to kuralis_products_path, 
                  notice: "Bulk listing process started for #{product_ids.count} products. You'll be notified when complete."
    end

    private

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
