class AddProfileIdsToEbayProductAttributes < ActiveRecord::Migration[8.0]
  def change
    add_column :ebay_product_attributes, :payment_profile_id, :string
    add_column :ebay_product_attributes, :return_profile_id, :string

    add_index :ebay_product_attributes, :payment_profile_id
    add_index :ebay_product_attributes, :return_profile_id
  end
end
