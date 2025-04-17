class CreateAiProductAnalyses < ActiveRecord::Migration[8.0]
  def change
    create_table :ai_product_analyses do |t|
      t.references :shop, null: false, foreign_key: true
      t.string :image, null: false
      t.string :status, null: false, default: 'pending'
      t.jsonb :results, default: {}
      t.boolean :processed, null: false, default: false

      t.timestamps
    end
    
    add_index :ai_product_analyses, :status
    add_index :ai_product_analyses, :processed
  end
end
