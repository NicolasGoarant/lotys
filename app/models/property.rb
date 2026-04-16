class Property < ApplicationRecord
  belongs_to :user
  has_many :documents, dependent: :destroy
  has_one :analysis, dependent: :destroy
  has_one :valuation, dependent: :destroy
  has_one :device_simulation, dependent: :destroy
  has_many :offers, dependent: :destroy
  has_many :local_aid_results, dependent: :destroy
  has_many_attached :photos do |attachable|
    attachable.variant :thumb,  resize_to_limit: [400, 300], format: :jpeg, saver: { quality: 80 }
    attachable.variant :medium, resize_to_limit: [1200, 900], format: :jpeg, saver: { quality: 85 }
  end

  enum :status, { draft: 0, analyzing: 1, analyzed: 2, published: 3 }
  enum :property_type, { appartement: "appartement", maison: "maison" }, prefix: :kind
  def local_aids_total_max
    local_aid_results.eligible.sum { |r| r.total_max_amount.to_i }
  end

end
