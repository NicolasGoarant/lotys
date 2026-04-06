class LocalAidResult < ApplicationRecord
  belongs_to :property
  belongs_to :local_aid_scheme

  scope :eligible, -> { where(eligible: true) }

  def total_max_amount
    amounts.values.compact.max
  end

  def amount_for(bracket)
    amounts[bracket.to_s]
  end
end
