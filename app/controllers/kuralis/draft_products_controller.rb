module Kuralis
  class DraftProductsController < AuthenticatedController
    layout "authenticated"

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

    # Start a sequential finalization flow for draft products
    def start_finalize_sequence
      draft_count = current_shop.kuralis_products.draft.count

      if draft_count == 0
        redirect_to kuralis_ai_product_analyses_path, alert: "No draft products to finalize."
        return
      end

      # Store total count in session for progress tracking
      session[:draft_finalize_total] = draft_count
      session[:draft_finalize_remaining] = draft_count

      # Get the first draft product and redirect to edit
      first_draft = current_shop.kuralis_products.draft.order(created_at: :asc).first
      redirect_to edit_kuralis_product_path(first_draft, finalize: true, sequence: true)
    end
  end
end
