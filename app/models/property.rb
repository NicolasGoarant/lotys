class Property < ApplicationRecord
  belongs_to :user
  has_many :documents, dependent: :destroy
  has_one :analysis, dependent: :destroy
  has_one :valuation, dependent: :destroy
  has_one :device_simulation, dependent: :destroy
  has_many :offers, dependent: :destroy

  enum status: { draft: 0, analyzing: 1, analyzed: 2, published: 3 }
  enum property_type: { appartement: 0, maison: 1 }, _prefix: :kind
end
