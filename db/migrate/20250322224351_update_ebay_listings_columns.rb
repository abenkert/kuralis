class UpdateEbayListingsColumns < ActiveRecord::Migration[7.1]
  def change
    # Add payment_profile_id if it doesn't exist
    unless column_exists?(:ebay_listings, :payment_profile_id)
      add_column :ebay_listings, :payment_profile_id, :string
    end

    # Add return_profile_id if it doesn't exist
    unless column_exists?(:ebay_listings, :return_profile_id)
      add_column :ebay_listings, :return_profile_id, :string
    end

    # Remove is_draft if it exists
    if column_exists?(:ebay_listings, :is_draft)
      remove_column :ebay_listings, :is_draft
    end
  end
end
