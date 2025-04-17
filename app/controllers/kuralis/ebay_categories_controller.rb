class Kuralis::EbayCategoriesController < AuthenticatedController
  # GET /kuralis/ebay_categories/search
  # Search for eBay categories by name
  def search
    query = params[:q].to_s.strip
    marketplace_id = params[:marketplace_id] || "EBAY_US"

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
    @marketplace_id = params[:marketplace_id] || "EBAY_US"
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

  # GET /kuralis/ebay_categories/:id/item_specifics
  def item_specifics
    category_id = params[:id]
    marketplace_id = params[:marketplace_id] || "EBAY_US"

    # Check if we have cached item specifics
    cached_specifics = EbayCategory.find_by(category_id: category_id, marketplace_id: marketplace_id)&.metadata&.dig("item_specifics")

    if cached_specifics.present?
      @item_specifics = cached_specifics
    else
      # Fetch from eBay API
      ebay_account = current_shop.shopify_ebay_account
      if ebay_account.present?
        service = Ebay::TaxonomyService.new(ebay_account)
        @item_specifics = service.fetch_item_aspects(category_id)

        # Cache the results in the category metadata
        category = EbayCategory.find_by(category_id: category_id, marketplace_id: marketplace_id)
        if category.present?
          metadata = category.metadata || {}
          metadata["item_specifics"] = @item_specifics
          category.update(metadata: metadata)
        end
      else
        @item_specifics = []
      end
    end

    respond_to do |format|
      format.json { render json: @item_specifics }
    end
  end

  # GET /kuralis/ebay_categories/:id
  # Get a specific eBay category by ID
  def show
    category_id = params[:id]
    marketplace_id = params[:marketplace_id] || "EBAY_US"

    @category = EbayCategory.find_by(category_id: category_id, marketplace_id: marketplace_id)

    if @category.present?
      @category_data = @category.as_json
      @category_data["full_path"] = @category.full_path
    else
      @category_data = {
        category_id: category_id,
        name: "Category #{category_id}",
        full_path: "Unknown Category Path",
        leaf: true
      }
    end

    respond_to do |format|
      format.html # show.html.erb
      format.json { render json: @category_data }
    end
  end
end
