class AddEmbeddingJsonToEbayCategories < ActiveRecord::Migration[8.0]
  def change
    add_column :ebay_categories, :embedding_json, :jsonb
  end
end
