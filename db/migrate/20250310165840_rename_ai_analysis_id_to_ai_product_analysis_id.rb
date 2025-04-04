class RenameAiAnalysisIdToAiProductAnalysisId < ActiveRecord::Migration[8.0]
  def change
    rename_column :kuralis_products, :ai_analysis_id, :ai_product_analysis_id if column_exists?(:kuralis_products, :ai_analysis_id)
  end
end
