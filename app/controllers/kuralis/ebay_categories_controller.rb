class Kuralis::EbayCategoriesController < ApplicationController
  
  # GET /kuralis/ebay_categories/search
  # Search for eBay categories by name
  def search
    query = params[:q].to_s.strip
    marketplace_id = params[:marketplace_id] || 'EBAY_US'
    
    if query.present? && query.length >= 2
      @categories = EbayCategory.search_with_path(query, marketplace_id)
    else
      @categories = []
    end
    
    respond_to do |format|
      format.html # search.html.erb
      format.json { render json: @categories }
    end
  end
  
  # POST /kuralis/ebay_categories/import
  # Trigger import of eBay categories
  def import
    ebay_account = current_shop.shopify_ebay_account
    
    if ebay_account.present?
      ImportEbayCategoriesJob.perform_later(ebay_account.id)
      
      respond_to do |format|
        format.html do
          flash[:notice] = "eBay category import has been scheduled. This may take a few minutes."
          redirect_to kuralis_settings_path
        end
        format.turbo_stream do
          flash.now[:notice] = "eBay category import has been scheduled. This may take a few minutes."
          render turbo_stream: turbo_stream.prepend("flash", partial: "shared/flash")
        end
        format.json { render json: { message: "Import scheduled" }, status: :ok }
      end
    else
      respond_to do |format|
        format.html do
          flash[:alert] = "You need to connect your eBay account first."
          redirect_to kuralis_settings_path
        end
        format.turbo_stream do
          flash.now[:alert] = "You need to connect your eBay account first."
          render turbo_stream: turbo_stream.prepend("flash", partial: "shared/flash")
        end
        format.json { render json: { error: "eBay account not connected" }, status: :unprocessable_entity }
      end
    end
  end
  
  # GET /kuralis/ebay_categories
  # List all eBay categories (paginated)
  def index
    @marketplace_id = params[:marketplace_id] || 'EBAY_US'
    @parent_id = params[:parent_id]
    
    @categories = if @parent_id.present?
                    EbayCategory.where(parent_id: @parent_id, marketplace_id: @marketplace_id)
                  else
                    EbayCategory.roots.where(marketplace_id: @marketplace_id)
                  end
                  
    @categories = @categories.order(:name).page(params[:page]).per(100)
    
    respond_to do |format|
      format.html # index.html.erb
      format.json { render json: @categories }
    end
  end
end
