class UpdateImagesFieldOnKuralisProducts < ActiveRecord::Migration[7.0]
  def change
    # Rename the JSON column from 'images' to 'image_urls'
    rename_column :kuralis_products, :images, :image_urls

    # Add images_last_synced_at column for tracking
    add_column :kuralis_products, :images_last_synced_at, :datetime
  end
end