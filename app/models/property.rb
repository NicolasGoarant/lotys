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

  # Liste des équipements stockés comme booléens dans le jsonb equipements_selection.
  # Utilisée pour surcharger les setters générés par store_accessor (voir plus bas).
  EQUIPEMENT_BOOL_KEYS = %i[
    pac_air_eau pac_geothermique
    chauffe_eau_thermo chauffe_eau_solaire
    systeme_solaire_combine pvt_eau
    poele_buches poele_granules insert_foyer
    raccordement_reseau_chaleur depose_fioul
    vmc_double_flux audit_energetique
  ].freeze

  # store_accessor génère readers + writers, mais les writers ne coercent PAS
  # les valeurs avant stockage dans le jsonb. Résultat : check_box envoie "1"/"0"
  # (strings) et c'est stocké tel quel dans la DB, alors que le sync Claude
  # stocke de vrais booléens. On surcharge les writers pour coercer proprement.
  store_accessor :equipements_selection,
                 *EQUIPEMENT_BOOL_KEYS, :nb_parois_vitrees

  # Surcharge des setters booléens : coercion via ActiveModel::Type::Boolean
  # qui gère "1", "true", "t", "yes", "on", 1, true → true
  #  et "0", "false", "f", "no", "off", 0, false, "" → false
  # write_store_attribute est l'API officielle Rails pour écrire dans un jsonb
  # via store_accessor en préservant le dirty tracking (equipements_selection_changed?).
  EQUIPEMENT_BOOL_KEYS.each do |key|
    define_method("#{key}=") do |value|
      casted = ActiveModel::Type::Boolean.new.cast(value)
      write_store_attribute(:equipements_selection, key, casted)
    end
  end

  # Surcharge pour nb_parois_vitrees : coercion en entier, "" ou nil → 0
  def nb_parois_vitrees=(value)
    casted = value.to_s.strip.empty? ? 0 : value.to_i
    write_store_attribute(:equipements_selection, :nb_parois_vitrees, casted)
  end

  def local_aids_total_max
    local_aid_results.eligible.sum { |r| r.total_max_amount.to_i }
  end
end
