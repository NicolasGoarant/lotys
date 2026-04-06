class Document < ApplicationRecord
  belongs_to :property
  has_one_attached :file
  validates :document_type, presence: true
  enum document_type: {
    dpe: 0, titre_propriete: 1, pv_ag: 2,
    devis: 3, photo: 4, autre: 5
  }
  scope :processed, -> { where(processed: true) }
end
