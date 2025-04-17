class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable

  belongs_to :shop, optional: true
  
  validates :email, presence: true, uniqueness: true
  validates :shop_id, uniqueness: true, allow_nil: true
  
  def name
    "#{first_name} #{last_name}".strip
  end
end 