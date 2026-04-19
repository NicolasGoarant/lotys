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

  # ─── equipements_selection : détail MPR Par geste (13 booléens + nb_parois_vitrees) ───
  EQUIPEMENT_BOOL_KEYS = %i[
    pac_air_eau pac_geothermique
    chauffe_eau_thermo chauffe_eau_solaire
    systeme_solaire_combine pvt_eau
    poele_buches poele_granules insert_foyer
    raccordement_reseau_chaleur depose_fioul
    vmc_double_flux audit_energetique
  ].freeze

  store_accessor :equipements_selection,
                 *EQUIPEMENT_BOOL_KEYS, :nb_parois_vitrees

  EQUIPEMENT_BOOL_KEYS.each do |key|
    define_method("#{key}=") do |value|
      casted = ActiveModel::Type::Boolean.new.cast(value)
      write_store_attribute(:equipements_selection, key, casted)
    end
  end

  def nb_parois_vitrees=(value)
    casted = value.to_s.strip.empty? ? 0 : value.to_i
    write_store_attribute(:equipements_selection, :nb_parois_vitrees, casted)
  end

  # ─── travaux_selection : 7 cases à cocher (macro-postes) ─────────────────────
  # Source : TravauxMapperService::CANONICAL_CODES.
  # Pré-rempli par PropertyAnalysisJob selon les travaux proposés par Claude,
  # modifiable ensuite par le propriétaire via update_travaux_selection.
  TRAVAUX_BOOL_KEYS = %i[
    isolation_toiture
    isolation_murs
    isolation_plancher_bas
    chauffage
    chauffe_eau
    vmc
    menuiseries
  ].freeze

  store_accessor :travaux_selection, *TRAVAUX_BOOL_KEYS

  TRAVAUX_BOOL_KEYS.each do |key|
    define_method("#{key}=") do |value|
      casted = ActiveModel::Type::Boolean.new.cast(value)
      write_store_attribute(:travaux_selection, key, casted)
    end
  end

  # Retourne la liste des codes de travaux cochés (true uniquement).
  # Utilisé par la vue pour calculer budget, DPE cible estimé, etc.
  def travaux_actifs
    TRAVAUX_BOOL_KEYS.select do |key|
      ActiveModel::Type::Boolean.new.cast(send(key))
    end.map(&:to_s)
  end

  def local_aids_total_max
    local_aid_results.eligible.sum { |r| r.total_max_amount.to_i }
  end
end
