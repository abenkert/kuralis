class CreateNotificationTable < ActiveRecord::Migration[8.0]
  def change
    create_table :notifications do |t|
      t.references :shop, null: false, foreign_key: true
      t.string :title, null: false
      t.text :message, null: false
      t.string :category, null: false
      t.boolean :read, default: false
      t.jsonb :metadata, default: {}
      t.integer :failed_product_ids, array: true, default: []
      t.integer :successful_product_ids, array: true, default: []

      t.timestamps
    end

    add_index :notifications, [:shop_id, :read]
    add_index :notifications, [:shop_id, :category]
    add_index :notifications, :failed_product_ids, using: 'gin'
    add_index :notifications, :successful_product_ids, using: 'gin'
  end
end
