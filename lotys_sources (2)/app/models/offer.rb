class Offer < ApplicationRecord
  belongs_to :property
  belongs_to :user

  enum offer_type: { renovation: 0, financement: 1, achat_promoteur: 2 }
  enum status: { pending: 0, accepted: 1, rejected: 2, expired: 3 }
end
