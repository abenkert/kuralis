class CreateKuralisShopSettings < ActiveRecord::Migration[7.1]
  def change
    create_table :kuralis_shop_settings do |t|
      t.references :shop, null: false, foreign_key: true
      t.string :category, null: false
      t.string :key, null: false
      t.jsonb :value, null: false, default: {}
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :kuralis_shop_settings, [ :shop_id, :category, :key ], unique: true
    add_index :kuralis_shop_settings, [ :shop_id, :category ]
    add_index :kuralis_shop_settings, :key
  end
end
