module Kuralis
  class DraftProductsController < AuthenticatedController
    layout "authenticated"

    def create
      pp params
      analysis = current_shop.ai_product_analyses.find(params[:analysis_id])

      unless analysis.completed?
        respond_to do |format|
          format.html { redirect_to kuralis_ai_product_analyses_path, alert: "Analysis is not yet complete." }
          format.json { render json: { error: "Analysis not complete" }, status: :unprocessable_entity }
        end
        return
      end

      existing_product = KuralisProduct.find_by(ai_product_analysis_id: analysis.id, is_draft: true)
      if existing_product.present?
        respond_to do |format|
          format.html { redirect_to edit_kuralis_product_path(existing_product, finalize: true), notice: "Editing existing draft product." }
          format.json { render json: { redirect: edit_kuralis_product_path(existing_product, finalize: true) } }
        end
        return
      end

      draft_product = KuralisProduct.create_from_ai_analysis(analysis, current_shop)

      if draft_product.persisted?
        respond_to do |format|
          format.html { redirect_to edit_kuralis_product_path(draft_product, finalize: true), notice: "Draft product created. Please review and finalize it." }
          format.json { render json: { redirect: edit_kuralis_product_path(draft_product, finalize: true) } }
        end
      else
        error_messages = draft_product.errors.full_messages

        if draft_product.ebay_product_attribute&.errors&.any?
          error_messages += draft_product.ebay_product_attribute.errors.full_messages
        end

        respond_to do |format|
          format.html { redirect_to kuralis_ai_product_analyses_path, alert: "Failed to create draft product: #{error_messages.join(', ')}" }
          format.json { render json: { error: error_messages }, status: :unprocessable_entity }
        end
      end
    end

    def create_all
      # Find all completed analyses that haven't been processed yet
      completed_analyses = current_shop.ai_product_analyses.completed.unprocessed

      created_count = 0
      failed_count = 0

      completed_analyses.each do |analysis|
        # Skip if a draft already exists for this analysis
        next if KuralisProduct.exists?(ai_product_analysis_id: analysis.id)

        draft_product = KuralisProduct.create_from_ai_analysis(analysis, current_shop)

        if draft_product.persisted?
          created_count += 1
        else
          failed_count += 1
        end
      end

      if created_count > 0
        message = "Successfully created #{created_count} draft products."
        message += " #{failed_count} failed to create." if failed_count > 0
        redirect_to kuralis_ai_product_analyses_path(tab: "drafts"), notice: message
      else
        redirect_to kuralis_ai_product_analyses_path, alert: "No draft products were created."
      end
    end
  end
end
