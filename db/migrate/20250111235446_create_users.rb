class CreateUsers < ActiveRecord::Migration[7.0]
  def change
    create_table :users do |t|
      t.string :email, null: false
      t.string :encrypted_password, null: false
      t.string :first_name
      t.string :last_name
      t.references :shop, foreign_key: true
      
      ## Devise fields
      t.string   :reset_password_token
      t.datetime :reset_password_sent_at
      t.datetime :remember_created_at

      t.timestamps
    end

    add_index :users, :email, unique: true
    add_index :users, :reset_password_token, unique: true
  end
end