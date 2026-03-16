class LocalAidScheme < ApplicationRecord
  has_many :local_aid_results, dependent: :destroy

  validates :name,      presence: true
  validates :territory, presence: true
  validates :aid_type,  presence: true, inclusion: { in: %w[renov_globale isolation] }

  scope :active, -> { where(active: true) }
  scope :currently_valid, -> {
    active
      .where("valid_from IS NULL OR valid_from <= ?", Date.today)
      .where("valid_until IS NULL OR valid_until >= ?", Date.today)
  }

  def covers_zipcode?(zipcode)
    zipcodes.include?(zipcode.to_s)
  end

  def covers_property_type?(ptype)
    property_types.nil? || property_types.include?(ptype.to_s)
  end

  def eligible_for?(property)
    covers_zipcode?(property.zipcode) && covers_property_type?(property.property_type)
  end

  def amount_for(bracket)
    case bracket.to_sym
    when :tres_modeste   then max_tres_modeste
    when :modeste        then max_modeste
    when :intermediaire  then max_intermediaire
    when :superieur      then max_superieur
    end
  end

  def renov_globale? = aid_type == "renov_globale"
  def isolation?     = aid_type == "isolation"

  def aid_type_label
    renov_globale? ? "Rénovation globale" : "Isolation"
  end
end
