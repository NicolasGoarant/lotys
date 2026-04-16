class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable, :confirmable
  enum :role, { proprietaire: 0, prestataire: 1, admin: 2 }
  after_initialize { self.role ||= :proprietaire }

  has_many :properties, dependent: :destroy
  has_many :offers
end
