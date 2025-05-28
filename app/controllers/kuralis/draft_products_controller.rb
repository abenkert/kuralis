module Kuralis
  class DraftProductsController < AuthenticatedController
    layout "authenticated"

    before_action :set_sequential_session, only: [ :sequential_edit, :sequential_update, :sequential_skip, :sequential_delete ]

    def create
      # DEPRECATED: Draft products are now created automatically after AI analysis
      analysis = current_shop.ai_product_analyses.find(params[:analysis_id])

      # Check if a draft already exists (should be created automatically)
      existing_product = KuralisProduct.find_by(ai_product_analysis_id: analysis.id, is_draft: true)

      if existing_product.present?
        respond_to do |format|
          format.html { redirect_to edit_kuralis_product_path(existing_product, finalize: true), notice: "Draft product found. Redirecting to edit." }
          format.json { render json: { redirect: edit_kuralis_product_path(existing_product, finalize: true) } }
        end
      else
        respond_to do |format|
          format.html { redirect_to kuralis_ai_product_analyses_path, notice: "Draft products are now created automatically. Please check the drafts tab." }
          format.json { render json: { message: "Draft products are created automatically" }, status: :ok }
        end
      end
    end

    def create_all
      # DEPRECATED: Draft products are now created automatically after AI analysis
      redirect_to kuralis_ai_product_analyses_path(tab: "drafts"),
                  notice: "Draft products are now created automatically after AI analysis completes. Check the drafts tab to review them."
    end

    # GET /kuralis/draft_products/start_finalize_sequence
    def start_finalize_sequence
      # Get all draft products for the current shop, ordered by creation date
      draft_products = current_shop.kuralis_products.draft.order(:created_at)

      if draft_products.empty?
        redirect_to kuralis_ai_product_analyses_path(tab: "drafts"),
                    alert: "No draft products available for finalization."
        return
      end

      # Create a session to track the sequential finalization process
      session[:sequential_finalization] = {
        draft_ids: draft_products.pluck(:id),
        current_index: 0,
        total_count: draft_products.count,
        completed_count: 0,
        skipped_ids: [],
        started_at: Time.current
      }

      # Redirect to the first draft
      redirect_to sequential_edit_kuralis_draft_products_path
    end

    # GET /kuralis/draft_products/sequential_edit
    def sequential_edit
      unless @sequential_session
        redirect_to kuralis_ai_product_analyses_path(tab: "drafts"),
                    alert: "Sequential finalization session not found."
        return
      end

      @current_draft = get_current_draft
      unless @current_draft
        # No more drafts to process
        complete_sequential_session
        return
      end

      # Prepare form data
      @product = @current_draft
      @product.build_ebay_product_attribute unless @product.ebay_product_attribute

      # Get progress information
      @progress = calculate_progress

      # Get confidence information
      @analysis = @current_draft.ai_product_analysis

      render :sequential_edit
    end

    # PATCH /kuralis/draft_products/sequential_update
    def sequential_update
      unless @sequential_session
        redirect_to kuralis_ai_product_analyses_path(tab: "drafts"),
                    alert: "Sequential finalization session not found."
        return
      end

      @current_draft = get_current_draft
      unless @current_draft
        complete_sequential_session
        return
      end

      # Update the draft product
      if @current_draft.update(product_params)
        # Try to finalize the product
        begin
          @current_draft.finalize!

          # Mark as completed in session
          @sequential_session["completed_count"] += 1
          advance_to_next_draft

          flash[:success] = "Product '#{@current_draft.title}' finalized successfully!"

          # Check if there are more drafts
          if get_current_draft
            redirect_to sequential_edit_kuralis_draft_products_path
          else
            complete_sequential_session
          end
        rescue ActiveRecord::RecordInvalid => e
          @product = @current_draft
          @progress = calculate_progress
          @analysis = @current_draft.ai_product_analysis

          flash.now[:error] = "Failed to finalize product: #{e.record.errors.full_messages.join(', ')}"
          render :sequential_edit
        end
      else
        @product = @current_draft
        @progress = calculate_progress
        @analysis = @current_draft.ai_product_analysis

        flash.now[:error] = "Please fix the errors below."
        render :sequential_edit
      end
    end

    # POST /kuralis/draft_products/sequential_skip
    def sequential_skip
      unless @sequential_session
        redirect_to kuralis_ai_product_analyses_path(tab: "drafts"),
                    alert: "Sequential finalization session not found."
        return
      end

      current_draft = get_current_draft
      if current_draft
        # Add to skipped list
        @sequential_session["skipped_ids"] << current_draft.id
        advance_to_next_draft

        flash[:info] = "Skipped '#{current_draft.title}'. You can finalize it later from the dashboard."
      end

      # Check if there are more drafts
      if get_current_draft
        redirect_to sequential_edit_kuralis_draft_products_path
      else
        complete_sequential_session
      end
    end

    # DELETE /kuralis/draft_products/sequential_delete
    def sequential_delete
      unless @sequential_session
        redirect_to kuralis_ai_product_analyses_path(tab: "drafts"),
                    alert: "Sequential finalization session not found."
        return
      end

      current_draft = get_current_draft
      if current_draft
        title = current_draft.title
        current_draft.destroy
        advance_to_next_draft

        flash[:info] = "Deleted draft '#{title}'."
      end

      # Check if there are more drafts
      if get_current_draft
        redirect_to sequential_edit_kuralis_draft_products_path
      else
        complete_sequential_session
      end
    end

    # POST /kuralis/draft_products/exit_sequence
    def exit_sequence
      session.delete(:sequential_finalization)
      redirect_to kuralis_ai_product_analyses_path(tab: "drafts"),
                  notice: "Exited sequential finalization. You can resume anytime."
    end

    private

    def set_sequential_session
      @sequential_session = session[:sequential_finalization]
    end

    def get_current_draft
      return nil unless @sequential_session

      current_index = @sequential_session["current_index"]
      draft_ids = @sequential_session["draft_ids"]

      return nil unless current_index && draft_ids
      return nil if current_index >= draft_ids.length

      current_id = draft_ids[current_index]

      draft = current_shop.kuralis_products.draft.find_by(id: current_id)

      draft
    end

    def advance_to_next_draft
      @sequential_session["current_index"] += 1
      session[:sequential_finalization] = @sequential_session
    end

    def calculate_progress
      {
        current: @sequential_session["current_index"] + 1,
        total: @sequential_session["total_count"],
        completed: @sequential_session["completed_count"],
        percentage: ((@sequential_session["current_index"].to_f / @sequential_session["total_count"]) * 100).round(1)
      }
    end

    def complete_sequential_session
      completed_count = @sequential_session&.[]("completed_count") || 0
      skipped_count = @sequential_session&.[]("skipped_ids")&.length || 0
      total_count = @sequential_session&.[]("total_count") || 0

      session.delete(:sequential_finalization)

      redirect_to kuralis_ai_product_analyses_path(tab: "drafts"),
                  notice: "Sequential finalization complete! Finalized #{completed_count} products, skipped #{skipped_count} out of #{total_count} total."
    end

    def product_params
      params.require(:kuralis_product).permit(
        :title, :description, :base_price, :base_quantity, :brand, :condition, :weight_oz,
        tags: [],
        ebay_product_attribute_attributes: [
          :id, :category_id, :condition_id, :condition_description, :listing_duration,
          :best_offer_enabled, :shipping_profile_id, :payment_profile_id, :return_profile_id,
          :store_category_id, item_specifics: {}
        ]
      )
    end
  end
end
