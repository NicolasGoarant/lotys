class Property < ApplicationRecord
  # optional: true → autorise les Property orphelines (user_id nil),
  # créées dans le parcours d'estimation anonyme et rattachables plus tard
  # à un User via leur claim_token. L'invariant #rattachable ci-dessous
  # garantit qu'une Property sans user porte forcément un claim_token —
  # pas de bien « ni possédé ni revendicable » silencieux en DB.
  belongs_to :user, optional: true

  # Feature portail collectivité (niveau 1 B2G) : un bien créé depuis un
  # portail EPCI (GET /collectivites/:slug) est rattaché à la collectivité
  # correspondante. Optional car les biens créés depuis la voie publique
  # standard (/properties/new sans slug) n'en ont pas. Le rattachement
  # est reseté à NULL si l'adresse confirmée sort du ressort (garde-fou
  # C6, principe projet "pas de caution hors territoire").
  belongs_to :collectivite, optional: true

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

  # ─── Énergie de chauffage (entrée du moteur DpeEngineService) ─────────
  # Les 5 énergies modélisées par le moteur 3CL §5a/§5b + :inconnue pour
  # gérer l'absence honnête de donnée. Préfixe :energie pour éviter le
  # conflit de scope avec energie_chauffage_source qui partage :inconnue.
  ENERGIES_CHAUFFAGE = %w[gaz fioul electricite bois pac inconnue].freeze
  enum :energie_chauffage,
       ENERGIES_CHAUFFAGE.zip(ENERGIES_CHAUFFAGE).to_h,
       prefix: :energie

  # Source de capture de energie_chauffage. La hiérarchie de confiance est
  # définie dans ENERGIE_SOURCE_HIERARCHIE ci-dessous ; une source basse ne
  # peut PAS écraser une source haute (cf. upgrade_energie_source?).
  ENERGIE_CHAUFFAGE_SOURCES = %w[
    extrait_dpe extrait_description deduit confirme_utilisateur inconnue
  ].freeze
  enum :energie_chauffage_source,
       ENERGIE_CHAUFFAGE_SOURCES.zip(ENERGIE_CHAUFFAGE_SOURCES).to_h,
       prefix: :source

  # Hiérarchie de confiance des sources (rang croissant = plus fiable).
  # Une nouvelle source écrase l'actuelle UNIQUEMENT si son rang est supérieur.
  #   inconnue (0) — aucune info
  #   deduit (1)   — proxy (ex. equipements_selection["depose_fioul"]=true → fioul)
  #   extrait_description (2) — heating_system JSON Claude depuis ai_summary/PDF
  #   extrait_dpe (3) — extraction directe d'un PDF DPE (plus autoritaire)
  #   confirme_utilisateur (4) — saisie explicite du propriétaire (sommet)
  ENERGIE_SOURCE_HIERARCHIE = {
    "inconnue"             => 0,
    "deduit"               => 1,
    "extrait_description"  => 2,
    "extrait_dpe"          => 3,
    "confirme_utilisateur" => 4
  }.freeze

  # ─── Garde-fou "bien hors ressort de sa collectivité" (feature C6) ─
  # Un bien créé depuis un portail EPCI (/collectivites/:slug) porte
  # collectivite_id. Si l'adresse CONFIRMÉE tombe finalement hors du
  # territoire de la collectivité (code_insee ∉ collectivite.insee_codes),
  # on retire le rattachement — principe projet "jamais de caution
  # d'une collectivité sur un bien hors de son ressort".
  #
  # Appelé depuis :
  #   - PropertiesController#confirm_address (juste après le geocoding
  #     BAN qui pose code_insee),
  #   - PropertyAnalysisJob (idempotent, robuste à un re-run).
  #
  # No-op quand :
  #   - le bien n'a pas de collectivite_id (parcours public standard),
  #   - le code_insee n'est pas encore posé (analyse pas encore
  #     géocodée — on RE-vérifiera plus tard).
  #
  # Retourne true si un reset a eu lieu (utile pour logger côté
  # controller/job), false sinon.
  def reset_collectivite_if_off_territory!
    return false if collectivite_id.blank?
    return false if code_insee.blank?
    return false if collectivite&.covers_insee?(code_insee)

    Rails.logger.info(
      "[Property##{id}] hors ressort collectivité##{collectivite_id} " \
      "(code_insee=#{code_insee.inspect}) → reset collectivite_id"
    )
    # update_columns : contourne les validations. Le bien peut être en
    # cours d'analyse (address encore vide → validation
    # address_or_documents_provided échouerait avec update). Le reset
    # est un ajustement système (déconnexion d'un rattachement devenu
    # illégitime), pas une mise à jour métier — pas de callback à
    # déclencher, pas de re-validation nécessaire.
    update_columns(collectivite_id: nil)
    true
  end

  # Vrai si source_nouvelle est plus fiable que source_actuelle.
  # Garantit qu'un proxy déduit n'écrase jamais une extraction réelle,
  # et qu'une extraction ne contredit jamais une confirmation utilisateur.
  def self.upgrade_energie_source?(source_actuelle, source_nouvelle)
    cur = ENERGIE_SOURCE_HIERARCHIE.fetch((source_actuelle.presence || "inconnue").to_s)
    nv  = ENERGIE_SOURCE_HIERARCHIE.fetch(source_nouvelle.to_s)
    nv > cur
  end

  # ─── Chauffage collectif / individuel ─────────────────────────────────
  # Détecte si le chauffage du lot est COLLECTIF (chaudière commune de
  # copropriété). Consommé par ProposableGestesService pour EXCLURE le
  # geste « remplacement du chauffage » de la liste actionnable : un
  # propriétaire seul ne peut pas remplacer une chaudière collective
  # (vote AG requis) — proposer ce geste dans les cases à cocher donne
  # une matrice DPE mensongère et un chiffrage trompeur (la « part
  # copro » d'un remplacement collectif n'est pas un devis individuel).
  #
  # ── Heuristique (pas de champ explicite en base) ─────────────────────
  #   - Hors copropriété → toujours false (pas de collectif possible).
  #   - Copropriété + au moins un équipement individuel de chauffage
  #     détecté dans equipements_selection (PAC, poêle, insert, réseau
  #     de chaleur, dépose fioul) → false : le lot a bien son propre
  #     système.
  #   - Copropriété + énergie gaz/fioul + aucun équipement individuel
  #     détecté → true (cas majoritaire : chaudière collective gaz).
  #   - Copropriété + énergie électrique/bois/PAC/inconnue → false
  #     (chauffage électrique en copro = convecteurs individuels ;
  #     bois/PAC = individuels de fait ; :inconnue = pas de signal
  #     collectif → conservateur côté proposable).
  #
  # À l'avenir : peut être remplacé par un champ explicite extrait du
  # DPE (rubrique « installation collective / individuelle ») avec le
  # même pattern que energie_chauffage_source (hiérarchie de sources).
  # En attendant, cette dérivation permet à ProposableGestesService
  # de trancher sans nouvelle colonne.
  EQUIPEMENTS_CHAUFFAGE_INDIVIDUELS = %w[
    pac_air_eau pac_geothermique
    poele_buches poele_granules insert_foyer
    raccordement_reseau_chaleur depose_fioul
  ].freeze

  def chauffage_collectif?
    return false unless is_copropriete
    selection = equipements_selection || {}
    cast = ActiveModel::Type::Boolean.new
    return false if EQUIPEMENTS_CHAUFFAGE_INDIVIDUELS.any? { |k| cast.cast(selection[k]) }
    %w[gaz fioul].include?(energie_chauffage.to_s)
  end

  # Proxy fioul : si l'analyse a marqué depose_fioul=true dans
  # equipements_selection (sémantique du prompt PropertyAnalysisService :
  # « depose_fioul = true si chauffage fioul actuel détecté »), on en déduit
  # energie_chauffage = :fioul, source = :deduit.
  # Ne touche à rien si une source plus fiable a déjà été posée.
  # Retourne true si l'écriture a eu lieu, false sinon.
  def appliquer_proxy_fioul_depuis_equipements!
    selection = equipements_selection || {}
    return false unless ActiveModel::Type::Boolean.new.cast(selection["depose_fioul"])
    return false unless Property.upgrade_energie_source?(energie_chauffage_source, "deduit")
    update(energie_chauffage: "fioul", energie_chauffage_source: "deduit")
  end

  # ─── Constantes partagées (inclusions de validations) ────────────────
  DPE_CLASSES      = %w[A B C D E F G].freeze
  INCOME_BRACKETS  = %w[tres_modeste modeste intermediaire superieur].freeze
  ADDRESS_SOURCES  = %w[dpe titre_propriete facture manuel].freeze

  # ─── Validations ─────────────────────────────────────────────────────
  # ── Adresse : substituable par des documents ───────────────────────
  # Depuis C2, l'adresse n'est plus strictement requise à la création.
  # Un utilisateur peut soumettre soit l'adresse (address+city+zipcode),
  # soit au moins un document (DPE, titre, facture) — le pipeline
  # d'extraction essaiera de déduire l'adresse.
  #
  # Le controller signale la présence d'uploads via documents_pending
  # AVANT save (les Documents ne sont attachés qu'après create). Pour un
  # bien déjà persisté, on regarde aussi documents.exists? — un update
  # ultérieur reste valide tant qu'il y a bien un document rattaché.
  attr_accessor :documents_pending

  validate :address_or_documents_provided
  validates :zipcode, format: {
    with: /\A\d{5}\z/,
    message: "doit être un code postal à 5 chiffres"
  }, allow_blank: true

  # Provenance de l'adresse : source d'extraction (dpe/titre_propriete/
  # facture) ou "manuel" si l'utilisateur a saisi lui-même. Optionnel
  # tant que l'adresse n'est pas confirmée — laisse la place au flux
  # de détection avant confirmation.
  validates :address_source, inclusion: { in: ADDRESS_SOURCES }, allow_blank: true

  # Publication : l'adresse doit être CONFIRMÉE. Sans ça, la commune
  # n'est pas fiable → LocalAidCalculator peut publier des aides à
  # côté de la plaque, /offers afficherait un bien sans code_insee
  # valable pour la carte. Bloquer à la publication (pas à
  # l'analyse) : l'utilisateur peut se balader dans son rapport tant
  # qu'il n'a pas confirmé.
  validate :address_confirmed_when_published

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

  # Invariant de rattachement : une Property doit être SOIT possédée
  # (user_id présent), SOIT revendicable (claim_token présent). Une ligne
  # sans aucun des deux serait orpheline ET non-récupérable — un déchet
  # silencieux. On la refuse à la validation.
  validate :rattachable

  private

  def rattachable
    # On reconnaît un rattachement valide si :
    #   - user_id est posé (cas usuel après save), OU
    #   - user est assigné en mémoire (cas `Property.new(user: u)` avant save), OU
    #   - claim_token est présent (orpheline revendicable).
    # Vérifier user_id seul ferait passer en faux-négatif un Property.new(user: u)
    # tant que le User n'a pas son id (cas typique des tests sans save).
    return if user_id.present? || user.present? || claim_token.present?

    errors.add(:base, "Un bien doit être rattaché à un utilisateur ou porter un jeton de revendication")
  end

  # Passe si :
  #   - les trois champs adresse sont saisis (chemin classique), OU
  #   - le controller a signalé un upload en cours (documents_pending), OU
  #   - le bien existe déjà avec au moins un document rattaché (update).
  def address_or_documents_provided
    return if address.present? && city.present? && zipcode.present?
    return if documents_pending
    return if persisted? && documents.exists?

    errors.add(:base,
      "Indiquez l'adresse du bien (avec code postal et ville) ou fournissez au moins un document (DPE, titre de propriété, facture).")
  end

  # Publication conditionnée à une adresse CONFIRMÉE. Une saisie manuelle
  # au create pose address_confirmed_at automatiquement (cf.
  # PropertiesController#create — C4). Une détection LLM ne suffit pas :
  # il faut le clic explicite du user sur le bandeau de confirmation.
  def address_confirmed_when_published
    return unless published?
    return if address_confirmed_at.present?

    errors.add(:base, "Confirmez l'adresse détectée avant de publier votre bien.")
  end
end
