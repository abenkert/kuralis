class AddDefaultLocationToShops < ActiveRecord::Migration[7.0]
  def change
    add_column :shops, :default_location_id, :string
  end
end