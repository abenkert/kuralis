class CreateWarehouses < ActiveRecord::Migration[8.0]
  def change
    create_table :warehouses do |t|
      t.references :shop, null: false, foreign_key: true
      t.string :name, null: false
      t.string :address1
      t.string :address2
      t.string :city
      t.string :state
      t.string :postal_code, null: false
      t.string :country_code, null: false
      t.boolean :is_default, default: false
      t.boolean :active, default: true

      t.timestamps
    end

    add_index :warehouses, [ :shop_id, :is_default ]
    add_index :warehouses, :postal_code
  end
end
