class AddLocationsToShops < ActiveRecord::Migration[7.0]
  def change
    add_column :shops, :locations, :jsonb, default: {}
  end
end
