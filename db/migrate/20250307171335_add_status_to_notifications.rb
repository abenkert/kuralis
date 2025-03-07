class AddStatusToNotifications < ActiveRecord::Migration[8.0]
  def change
    add_column :notifications, :status, :string, null: false, default: 'info'
    add_index :notifications, :status
  end
end
