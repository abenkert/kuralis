class CreatePlatformSyncFailures < ActiveRecord::Migration[8.0]
  def change
    create_table :platform_sync_failures do |t|
      t.references :kuralis_product, null: false, foreign_key: true
      t.references :shop, null: false, foreign_key: true
      t.json :failed_platforms, null: false
      t.json :successful_platforms, null: false
      t.json :error_details
      t.string :failure_type, null: false
      t.integer :retry_count, default: 0
      t.string :status, default: 'pending'
      t.timestamp :escalated_at
      t.timestamp :resolved_at
      t.timestamp :abandoned_at

      t.timestamps
    end

    add_index :platform_sync_failures, [ :shop_id, :status ]
    add_index :platform_sync_failures, [ :kuralis_product_id, :created_at ]
    add_index :platform_sync_failures, :created_at
    add_index :platform_sync_failures, [ :status, :retry_count ]
  end
end
