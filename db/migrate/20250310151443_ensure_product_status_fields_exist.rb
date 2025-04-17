class EnsureProductStatusFieldsExist < ActiveRecord::Migration[8.0]
  def change
    # Check if 'status' column exists in kuralis_products
    unless column_exists?(:kuralis_products, :status)
      add_column :kuralis_products, :status, :string, default: 'active'
      add_index :kuralis_products, :status
    end

    # Add a reference to ai_product_analyses if it doesn't exist
    unless column_exists?(:kuralis_products, :ai_product_analysis_id)
      add_reference :kuralis_products, :ai_product_analysis, foreign_key: { to_table: :ai_product_analyses }, index: true
    end
    
    # Make sure we have a 'is_draft' boolean field
    unless column_exists?(:kuralis_products, :is_draft)
      add_column :kuralis_products, :is_draft, :boolean, default: false
      add_index :kuralis_products, :is_draft
    end
  end
end
