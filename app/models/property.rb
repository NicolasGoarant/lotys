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

  # ─── Constantes partagées (inclusions de validations) ────────────────
  DPE_CLASSES      = %w[A B C D E F G].freeze
  INCOME_BRACKETS  = %w[tres_modeste modeste intermediaire superieur].freeze

  # ─── Validations ─────────────────────────────────────────────────────
  # Champs strictement requis : sans eux, impossible d'analyser ou de publier.
  validates :address, :city, :zipcode, presence: true
  validates :zipcode, format: {
    with: /\A\d{5}\z/,
    message: "doit être un code postal à 5 chiffres"
  }

  # Surface : optionnelle tant que le bien n'est pas publié — le parcours
  # "adresse seule" la remplit via l'analyse Claude après la création.
  # Si une valeur est fournie, elle doit être strictement positive (plafond
  # 10 000 m² au-delà duquel c'est probablement une saisie erronée).
  # Exigée au moment de la publication (cf. validation conditionnelle ci-dessous).
  validates :surface,
            numericality: { greater_than: 0, less_than: 10_000 },
            allow_nil: true
  validates :surface, presence: true, if: :published?

  # Année de construction : optionnelle (certains DPE anciens n'en ont pas),
  # mais si fournie, doit être entre 1500 et l'année courante.
  validates :construction_year,
            numericality: {
              only_integer: true,
              greater_than_or_equal_to: 1500,
              less_than_or_equal_to: ->(_p) { Date.current.year }
            },
            allow_nil: true

  # DPE : classe actuelle optionnelle tant que le bien n'est pas publié
  # (le parcours "adresse seule" la renseigne via l'analyse Claude). Si
  # une valeur est fournie elle doit être dans A→G. Exigée à la publication.
  # Classe cible toujours optionnelle.
  validates :dpe_class,  inclusion: { in: DPE_CLASSES }, allow_nil: true
  validates :dpe_class,  presence: true, if: :published?
  validates :dpe_target, inclusion: { in: DPE_CLASSES }, allow_nil: true

  # Nombre de pièces : optionnel mais > 0 si fourni.
  validates :nb_rooms,
            numericality: { only_integer: true, greater_than: 0 },
            allow_nil: true

  # Revenus : doit correspondre à un des brackets connus (utilisé par
  # AidCalculatorService pour calculer MPR/CEE).
  # income_bracket n'est plus saisi directement : il est dérivé de
  # household_size + rfr via IncomeBracketCalculator (cf. before_save).
  validates :income_bracket,
            inclusion: { in: INCOME_BRACKETS },
            allow_nil: true
  validates :household_size,
            numericality: { only_integer: true, greater_than: 0, less_than: 20 },
            allow_nil: true
  validates :rfr,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 },
            allow_nil: true

  # Dérive automatiquement la tranche de revenus depuis le couple
  # (nombre de personnes du foyer fiscal, revenu fiscal de référence).
  # Ne touche PAS à income_bracket si la dérivation échoue (rfr/size
  # vide ou nul) : les biens legacy gardent leur tranche existante
  # tant que l'utilisateur n'a pas renseigné les nouveaux champs.
  before_save :derive_income_bracket

  def derive_income_bracket
    derived = IncomeBracketCalculator.bracket_for(rfr: rfr, household_size: household_size)
    self.income_bracket = derived if derived.present?
  end

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
  # Lit directement depuis le hash jsonb pour éviter un conflit entre
  # store_accessor et ActiveModel::Type::Value.accessor (erreur silencieuse
  # sur certaines versions de Rails 7.2 avec des colonnes jsonb+default).
  def travaux_actifs
    selection = travaux_selection || {}
    TRAVAUX_BOOL_KEYS.each_with_object([]) do |key, arr|
      val = selection[key.to_s]
      arr << key.to_s if ActiveModel::Type::Boolean.new.cast(val)
    end
  end

  def local_aids_total_max
    local_aid_results.eligible.sum { |r| r.total_max_amount.to_i }
  end
end
