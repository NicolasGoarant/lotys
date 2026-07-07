class PropertiesController < ApplicationController
  before_action :authenticate_user!, except: [:index, :new, :create, :show,
                                              :confirm_address, :confirm_position_lot,
                                              :update_income_bracket]

  # Lecture : propriétaire toujours, prestataire uniquement si le bien est publié.
  before_action :set_property_for_read, only: [:show]

  # Confirmation d'adresse (C5) et confirmation de position du lot :
  # même règle d'autorisation — le propriétaire connecté OU le détenteur
  # du claim_token dans son cookie signé. Pas le fallback "published" :
  # un visiteur random n'a pas à toucher aux données du bien.
  before_action :set_property_for_confirm, only: [:confirm_address, :confirm_position_lot]

  # Édition du foyer fiscal : même règle que confirm_address —
  # propriétaire connecté OU claimant du navigateur, PAS le fallback
  # published. Le calcul des aides est le cœur de la valeur produit,
  # il DOIT être accessible à l'anonyme qui a créé le bien depuis le
  # parcours public. Un visiteur random d'un bien publié est refusé
  # (données fiscales = donnée sensible, cf. principe projet).
  before_action :set_property_for_edit_aids, only: [:update_income_bracket]

  # Écriture : uniquement le propriétaire. Toute tentative par un autre user
  # (même connecté) renvoie vers /properties avec alerte. Protège contre la
  # suppression, modification, publication, dépublication d'un bien
  # qui n'appartient pas à l'utilisateur courant.
  before_action :set_property_for_write, only: [
    :edit, :update, :destroy, :analyze, :publish, :unpublish, :preview,
    :update_dpe_target,
    :update_travaux, :update_travaux_selection
  ]

  def index
    if user_signed_in?
      @properties = current_user.properties.order(created_at: :desc)
      render :index
    else
      redirect_to root_path
    end
  end

  def show
    # Calcul des aides + projection : élargi au détenteur du claim_token
    # (parcours d'estimation anonyme), pas seulement au propriétaire
    # connecté. Sans cette extension, la vue rendrait le bloc Aides vide
    # pour le claimant — c'est le pendant serveur du fix vue.
    if (user_signed_in? && current_user == @property.user) || claimable_by_browser?(@property)
      # On passe travaux_actifs pour que le calcul d'aides reflète les
      # cases cochées par le propriétaire dans la card "Rénovation énergétique"
      # (travaux_selection jsonb). Sans ce paramètre, le service lirait
      # l'intégralité d'equipements_selection pré-rempli par l'analyse Claude,
      # ce qui surestimerait les aides une fois que l'utilisateur a décoché
      # un ou plusieurs travaux.
      #
      # Distinction importante :
      #   - travaux_selection jsonb vide ({}) → le bien vient d'être créé,
      #     l'utilisateur n'a rien vu encore : on passe nil (pas de filtre).
      #   - travaux_selection rempli avec toutes les cases décochées
      #     (ex. {"chauffage"=>false,...}) → on passe [] au service pour
      #     refléter le choix explicite de l'utilisateur (aides = 0).
      travaux_actifs_param = @property.travaux_selection.present? ? @property.travaux_actifs : nil

      # Matrice DPE pré-calculée (PropertyDpeMatrixService) : on la calcule
      # ICI plutôt que dans la vue pour deux raisons.
      #   1. Le calcul d'aides ci-dessous a besoin de la classe atteignable
      #      par les gestes cochés pour rester aligné avec la jauge — sans
      #      ça, AidCalculator lit @property.dpe_target (forfait) et donne
      #      des montants incohérents avec ce que voit l'utilisateur.
      #   2. La vue réutilise @dpe_matrix tel quel (cf. show.html.erb), donc
      #      on ne paie le coût (~80 ms) qu'une fois par requête.
      # Conditions d'invocation identiques à celles historiquement utilisées
      # par la vue : surface + année. Le contrôle d'accès est déjà fait par
      # le if englobant — on est forcément autorisé ici.
      @dpe_matrix = if @property.surface.present? && @property.construction_year.present?
                      PropertyDpeMatrixService.call(@property)
                    end

      # Classe DPE réellement atteignable pour les gestes cochés. C'est la
      # même valeur qui pilote le pin de la jauge (cf. show.html.erb:91).
      # Clé de combinaison = `travaux_actifs.sort.join(",")` — format exact
      # produit par PropertyDpeMatrixService#calculer_combinaisons.
      # Reste nil si la matrice est absente (surface/année manquantes) ou
      # si la clé ne matche aucune combinaison (défensif) — AidCalculator
      # retombera alors sur @property.dpe_target via son fallback existant
      # (chemin de dégradation explicite, jamais silencieux).
      matrix_classe = if @dpe_matrix
                        cle = @property.travaux_actifs.sort.join(",")
                        @dpe_matrix.dig(:combinaisons, cle, :classe)
                      end

      # Cible DPE exposée à la vue pour le libellé « objectif X » de la
      # card Aides. Source unique = matrice quand disponible, sinon forfait
      # DB. Garantit que le label suit toujours ce que le calculateur a
      # effectivement utilisé.
      @dpe_target_effectif = (matrix_classe || @property.dpe_target).to_s.upcase

      @aid_result = AidCalculatorService.new(
        @property,
        travaux_actifs:      travaux_actifs_param,
        dpe_target_override: matrix_classe
      ).call

      # Projection LECTURE SEULE : "à la cible supérieure la plus proche
      # qui débloque, ça donnerait X €". Sert à l'UI à inviter sans mentir
      # (cf. AidProjectionService, garde-fous testés).
      # Retourne nil si rien à proposer (déjà optimal, revenus manquants,
      # ou aucune cible supérieure ne change le total) → pas d'invitation.
      # current_target : point de départ de l'itération vers les cibles
      # supérieures = classe matrice quand disponible, pour ne pas projeter
      # depuis le forfait DB pendant que la jauge montre autre chose.
      @aid_projection = AidProjectionService.call(
        @property,
        current_total:  @aid_result[:total_subventions],
        travaux_actifs: travaux_actifs_param,
        current_target: @dpe_target_effectif
      )
    end
    respond_to do |format|
      format.html
      format.json { render json: { status: @property.status } }
    end
  end

  def new
    @property = Property.new
    # Feature portail EPCI : quand l'utilisateur arrive depuis un
    # portail (/collectivites/:slug), le CTA passe collectivite=<slug>
    # en param. On charge la Collectivite pour pré-remplir le hidden
    # field et adapter la page (bandeau contextuel). find_by nil-safe :
    # si le slug est bidon ou la collectivité désactivée, on reste sur
    # le parcours public standard (zéro régression).
    @collectivite = Collectivite.active.find_by(slug: params[:collectivite]) if params[:collectivite].present?
  end

  def create
    if user_signed_in?
      if current_user.properties.count >= 3
        redirect_to properties_path, alert: "Vous avez atteint la limite de 3 biens par compte."
        return
      end
      @property = current_user.properties.build(property_params)
      @property.status = :analyzing
      prepare_address_flow(@property)
      if @property.save
        attach_uploaded_documents
        PropertyAnalysisJob.perform_later(@property.id)
        redirect_to @property, notice: "Analyse lancée — la page se met à jour automatiquement."
      else
        render :new, status: :unprocessable_entity
      end
    else
      # Parcours anonyme : on crée une Property ORPHELINE (user_id nil)
      # munie d'un claim_token aléatoire. Le jeton est aussi déposé en
      # cookie signé côté navigateur — c'est lui qui débloquera la lecture
      # via set_property_for_read (commit 2) et la revendication à
      # l'inscription/connexion (commit 4).
      token = SecureRandom.urlsafe_base64(32)
      @property = Property.new(property_params)
      @property.claim_token = token
      @property.status      = :analyzing
      prepare_address_flow(@property)
      if @property.save
        write_claim_cookie!(token)
        attach_uploaded_documents
        PropertyAnalysisJob.perform_later(@property.id)
        redirect_to @property, notice: "Analyse lancée — la page se met à jour automatiquement."
      else
        render :new, status: :unprocessable_entity
      end
    end
  end

  def edit
  end

  def update
    if @property.update(property_params)
      redirect_to @property, notice: "Bien mis à jour."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @property.destroy
    redirect_to properties_path, notice: "Bien supprimé."
  end

  def analyze
    # Property déclare `has_one :analysis` (singulier) : on n'a pas
    # d'association `.analyses`. On compte directement les lignes en DB
    # pour conserver le garde-fou "max 2 analyses par bien".
    if Analysis.where(property_id: @property.id).count >= 2
      redirect_to @property, alert: "Nombre maximum d'analyses atteint pour ce bien."
      return
    end
    PropertyAnalysisJob.perform_later(@property.id)
    redirect_to @property, notice: "Analyse lancée — la page se mettra à jour automatiquement."
  end

  def publish
    if @property.update(status: :published)
      redirect_to @property, notice: "Votre dossier est maintenant visible par les prestataires."
    else
      redirect_to @property,
                  alert: "Pour publier votre bien, complétez : #{@property.errors.full_messages.to_sentence}."
    end
  end

  def unpublish
    @property.update(status: :analyzed)
    redirect_to @property, notice: "Votre bien a été dépublié."
  end

  # Confirmation d'adresse (C5). L'utilisateur voit soit l'adresse
  # détectée par le LLM (address_detected, C3), soit un formulaire vide
  # s'il n'y a rien eu de détecté — dans les deux cas il valide (ou
  # corrige) puis on la fige dans address/city/zipcode.
  #
  # address_source : conservé si les 3 champs collent aux valeurs
  # _detected (l'utilisateur a validé la détection telle quelle),
  # bascule en "manuel" s'il a édité au moins un champ (la donnée
  # confirmée ne vient plus tout à fait du DPE/titre/facture).
  #
  # GeocodingService + LocalAidCalculator : appelés maintenant que la
  # commune est fiable. Ces deux services étaient retenus tant que
  # l'adresse n'était pas confirmée (cf. C4 job guard et C6 vue).
  def confirm_address
    attrs = params.require(:property).permit(:address, :city, :zipcode)
    if attrs[:address].blank? || attrs[:city].blank? || attrs[:zipcode].blank?
      redirect_to @property,
        alert: "Merci de renseigner l'adresse complète (numéro + rue, code postal, ville)."
      return
    end

    matches_detected = attrs[:address].strip == @property.address_detected.to_s.strip &&
                       attrs[:city].strip    == @property.city_detected.to_s.strip &&
                       attrs[:zipcode].strip == @property.zipcode_detected.to_s.strip
    new_source = matches_detected ? @property.address_source.presence || "manuel" : "manuel"

    @property.update!(
      address:              attrs[:address].strip,
      city:                 attrs[:city].strip,
      zipcode:              attrs[:zipcode].strip,
      address_source:       new_source,
      address_confirmed_at: Time.current
    )

    GeocodingService.new(@property).call
    # Garde-fou "hors ressort" (feature portail C6) : après le geocoding
    # BAN qui vient de poser code_insee, on vérifie que l'adresse
    # confirmée tombe bien dans le territoire de la collectivité de
    # rattachement. Sinon, on retire le rattachement (Property#reset_...).
    @property.reset_collectivite_if_off_territory!
    LocalAidCalculator.new(@property).call

    redirect_to @property, notice: "Adresse confirmée — vos aides locales sont recalculées."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to @property, alert: e.record.errors.full_messages.to_sentence
  end

  # Confirmation de la position du lot (appartements seulement — voir
  # migration AddPositionLotToProperties). Pattern parallèle à
  # confirm_address : l'utilisateur voit une valeur détectée
  # (position_lot_detected) et confirme/corrige ; la vue de vérité
  # (position_lot + position_lot_confirmed_at) n'est écrite qu'ici,
  # jamais par le pipeline d'extraction.
  #
  # Consommé en aval par ProposableGestesService (cases à cocher :
  # toiture / plancher exclus selon la position) et par DpeEngineService
  # (coefficients b de mitoyenneté verticale, commit 3).
  #
  # Ignoré pour une maison : le champ n'a pas de sens (toutes les parois
  # donnent sur l'extérieur par convention). Le bandeau côté vue n'est
  # rendu que pour les appartements, donc en pratique la route n'est
  # jamais appelée pour une maison.
  def confirm_position_lot
    valeur = params.dig(:property, :position_lot).to_s
    unless Property::POSITIONS_LOT.include?(valeur)
      redirect_to @property,
        alert: "Merci de choisir la position du lot dans la liste proposée."
      return
    end

    @property.update!(
      position_lot:              valeur,
      position_lot_confirmed_at: Time.current
    )
    redirect_to @property, notice: "Position du lot confirmée."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to @property, alert: e.record.errors.full_messages.to_sentence
  end

  def preview
  end

  def update_dpe_target
    @property.update(dpe_target: params[:dpe_target])
    redirect_to @property, notice: "Objectif DPE mis à jour."
  end

  # Met à jour le foyer fiscal (nb personnes + RFR). Accessible au
  # propriétaire connecté ET au claimant du navigateur (feature
  # "aides sans compte"). income_bracket est dérivé au before_save
  # via IncomeBracketCalculator (plafonds ALEC Nancy 2026). Le
  # recalcul des aides (MPR/CEE via AidCalculatorService) se fait
  # naturellement au prochain rendu de show — pas de service
  # spécifique à appeler.
  #
  # ── Contrat d'échec explicite (bug bien 232) ──
  # Sur prod, un utilisateur signalait des champs household_size / rfr
  # revenus à vide après « Calculer mes aides » puis un tour par
  # update_travaux_selection. Diagnostic : la DB n'a JAMAIS reçu les
  # valeurs — soit le POST n'a pas atteint le serveur (JS/browser),
  # soit une validation a échoué. Le code d'origine appelait
  # `@property.update(...)` sans vérifier le retour ET redirigeait avec
  # un notice de succès dans TOUS les cas. Résultat : « faux OK » côté
  # user, aucun signal pour investiguer côté serveur.
  # Nouveau contrat : on VÉRIFIE le retour et on redirige avec ALERT si
  # la sauvegarde échoue. Aucune régression pour les cas nominaux
  # (les tests H et H-bis passent en 302 → notice comme avant), mais
  # les cas dégradés cessent d'être silencieux.
  def update_income_bracket
    if @property.update(params.require(:property).permit(:household_size, :rfr))
      redirect_to property_path(@property, anchor: "aides"),
                  notice: "Foyer fiscal mis à jour — aides recalculées."
    else
      redirect_to property_path(@property, anchor: "aides"),
                  alert: "Impossible d'enregistrer le foyer fiscal : " \
                         "#{@property.errors.full_messages.to_sentence}."
    end
  end

  # Met à jour les quantités précises (formulaire expert MPR Par geste — non rendu
  # par défaut dans la vue, conservé pour usage futur).
  def update_travaux
    if @property.update(travaux_params)
      redirect_to @property, notice: "Travaux mis à jour — aides recalculées."
    else
      redirect_to @property, alert: "Erreur : #{@property.errors.full_messages.to_sentence}"
    end
  end

  # Persiste la sélection des 7 cases à cocher macro dans travaux_selection,
  # plus la cible DPE choisie via le slider (dpe_target). Redirige vers la
  # fiche avec ancre #travaux pour que l'utilisateur reste scrollé sur la
  # card Rénovation énergétique.
  def update_travaux_selection
    # On construit le hash à persister EN CONSTRUISANT EXPLICITEMENT
    # chaque clé depuis les params, pour éviter que :
    #   - les cases décochées (value "0") ne soient ignorées
    #   - les setters store_accessor ne remettent des valeurs par défaut
    # Résultat : on écrit le jsonb entier d'un seul coup via update_column,
    # qui bypasse les accesseurs et garantit une écriture propre.
    params_permis = travaux_selection_params
    bool_cast = ActiveModel::Type::Boolean.new

    new_selection = Property::TRAVAUX_BOOL_KEYS.each_with_object({}) do |key, h|
      raw = params_permis[key]
      if raw.nil?
        existing = (@property.travaux_selection || {})[key.to_s]
        h[key.to_s] = bool_cast.cast(existing) unless existing.nil?
      else
        h[key.to_s] = bool_cast.cast(raw)
      end
    end

    @property.update_column(:travaux_selection, new_selection)

    # Persistance de la cible DPE (positionnée via le slider JS).
    # Nécessaire pour que Grand Nancy rénovation globale bascule en actif
    # si l'utilisateur vise A ou B.
    dpe_target_raw = params_permis[:dpe_target].to_s.upcase
    if %w[A B C D E F G].include?(dpe_target_raw) && dpe_target_raw != @property.dpe_target
      @property.update_column(:dpe_target, dpe_target_raw)
    end

    # Comble les colonnes structurées (surface_*, equipements_selection) là où
    # l'analyse Claude n'a rien posé, avec des estimations par défaut dérivées
    # des macros cochés. Sans ce shim, AidCalculatorService renvoie "Aucune
    # aide retenue" tant qu'aucun DPE/devis n'a alimenté quantites_mpr.
    # Pose le drapeau inputs_estimes lu par la vue pour afficher honnêtement
    # "estimation, lancez l'analyse pour affiner".
    TravauxDefaultsDeriver.new(@property).call!

    redirect_to property_path(@property, anchor: "travaux")
  end

  private

  def run_analysis(property)
    property.update(status: :analyzing)
    GeocodingService.new(property).call
    property.documents.each do |doc|
      DocumentAnalysisService.new(doc).call if doc.file.attached?
    end
    PropertyDataExtractorService.new(property).call
    DvfEstimationService.new(property).call
    DeviceSimulationService.new(property).call
    PropertyAnalysisService.new(property).call
    LocalAidCalculator.new(property).call
    sync_analysis_fields(property)
    property.update(status: :analyzed)
  end

  def sync_analysis_fields(property)
    return unless property.analysis&.content.present?
    parsed = JSON.parse(property.analysis.content) rescue nil
    return unless parsed

    updates = {}

    if property.dpe_target.blank?
      dpe_cible = parsed.dig("energie", "dpe_cible")&.upcase
      updates[:dpe_target] = dpe_cible if dpe_cible.present? && %w[A B C D E F G].include?(dpe_cible)
    end

    if property.dpe_class.blank?
      dpe_estime = parsed.dig("energie", "dpe_estime")&.upcase
      updates[:dpe_class] = dpe_estime if dpe_estime.present? && %w[A B C D E F G].include?(dpe_estime)
    end

    property.update(updates) if updates.any?
    Rails.logger.info("sync_analysis_fields: #{updates.keys.join(', ')}")
  rescue => e
    Rails.logger.error("sync_analysis_fields failed: #{e.message}")
  end

  def attach_photos
    photos = params.dig(:property, :photos)
    return unless photos.present?
    valid = Array(photos).select { |f| f.content_type.start_with?("image/") rescue false }.first(10)
    @property.photos.attach(valid) if valid.any?
  end

  def attach_uploaded_documents
    uploaded = params.dig(:property, :uploaded_files)
    return unless uploaded.present?

    Array(uploaded).each do |file|
      next unless file.respond_to?(:original_filename)

      doc = @property.documents.build(
        document_type: :autre,
        name: file.original_filename
      )
      doc.file.attach(file)
      doc.save
    end
  end

  # C2 : deux rôles autour du flux "adresse facultative".
  #
  # 1. documents_pending — signale à Property#address_or_documents_provided
  #    qu'un ou plusieurs uploads accompagnent la soumission. La validation
  #    tourne AVANT save, donc AVANT attach_uploaded_documents : sans ce
  #    flag, elle ne verrait aucun document rattaché et rejetterait la
  #    création. attr_accessor purement mémoire, non persisté.
  #
  # 2. Saisie manuelle = confirmation implicite. Si l'utilisateur a écrit
  #    lui-même les 3 champs adresse (nominal), on pose address_source
  #    = "manuel" et address_confirmed_at = maintenant. Le principe
  #    "ne jamais analyser sur hypothèse non validée" concerne la
  #    détection LLM ; ce que le user écrit lui-même est confirmé
  #    d'office. Sans ça, la publication resterait bloquée dans le
  #    chemin nominal (cf. Property#address_confirmed_when_published).
  def prepare_address_flow(property)
    uploaded = params.dig(:property, :uploaded_files)
    property.documents_pending = uploaded.present?

    if property.address.present? && property.city.present? && property.zipcode.present?
      property.address_source       ||= "manuel"
      property.address_confirmed_at ||= Time.current
    end
  end

  # Lecture — trois voies d'autorisation, dans cet ordre :
  #   1. propriétaire connecté → son bien, quel que soit le status (draft inclus)
  #   2. orpheline (user_id nil) ET claim_token présent dans le cookie signé
  #      de CE navigateur → autorisée. Le cookie est inviolable côté client,
  #      donc un autre visiteur ne peut pas usurper le jeton.
  #   3. fallback : Property.published.find(id) — visible par tous, y compris
  #      non connectés. Une orpheline ne peut pas être publiée (l'invariant
  #      #rattachable + le flux de publication exigent un user), donc le
  #      fallback ne révèle jamais une orpheline d'un autre navigateur.
  # Ne fait PAS crasher sur user non connecté (bug précédent : current_user nil).
  def set_property_for_read
    if user_signed_in? && current_user.properties.exists?(id: params[:id])
      @property = current_user.properties.find(params[:id])
      return
    end

    candidate = Property.find_by(id: params[:id])
    if candidate && claimable_by_browser?(candidate)
      @property = candidate
      return
    end

    @property = Property.published.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to root_path, alert: "Ce bien n'existe pas ou n'est plus disponible."
  end

  # Écriture : accès strict au propriétaire. N'importe quelle autre demande
  # (prestataire, autre propriétaire, etc.) est bloquée.
  # Corrige le bug où un user connecté pouvait supprimer/modifier le bien
  # d'un autre user simplement parce qu'il était publié.
  def set_property_for_write
    @property = current_user.properties.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to properties_path, alert: "Vous n'avez pas accès à ce bien."
  end

  # Confirmation d'adresse (C5) — propriétaire connecté OU claimant
  # anonyme via cookie signé. Le parcours "documents sans adresse"
  # (C2) crée volontairement une Property orpheline : sans cette
  # branche claim_token, l'orphelin ne pourrait jamais confirmer.
  def set_property_for_confirm
    if user_signed_in? && current_user.properties.exists?(id: params[:id])
      @property = current_user.properties.find(params[:id])
      return
    end
    candidate = Property.find_by(id: params[:id])
    if candidate && claimable_by_browser?(candidate)
      @property = candidate
      return
    end
    redirect_to root_path, alert: "Vous n'avez pas accès à ce bien."
  end

  # Édition du foyer fiscal (household_size + rfr) — même règle
  # d'autorisation que set_property_for_confirm : propriétaire OU
  # claimant du navigateur. Le calcul des aides doit rester
  # accessible à l'anonyme qui a créé le bien depuis le parcours
  # public (principe "sans capture de coordonnées"). Un visiteur
  # random d'un bien published est refusé — les données fiscales
  # sont sensibles.
  def set_property_for_edit_aids
    if user_signed_in? && current_user.properties.exists?(id: params[:id])
      @property = current_user.properties.find(params[:id])
      return
    end
    candidate = Property.find_by(id: params[:id])
    if candidate && claimable_by_browser?(candidate)
      @property = candidate
      return
    end
    redirect_to root_path, alert: "Vous n'avez pas accès à ce bien."
  end

  def property_params
    params.require(:property).permit(
      :address, :city, :zipcode, :surface, :property_type,
      :construction_year, :dpe_class, :nb_rooms, :nb_lots,
      :is_copropriete, :vacant, :source,
      :vacancy_duration, :vacancy_reason, :dpe_target, :income_bracket,
      :household_size, :rfr,
      :collectivite_id,  # feature portail EPCI — nullable, garde-fou C6
                         # reset à NULL si code_insee hors ressort
                         # (cf. Property#reset_collectivite_if_off_territory!)
      photos: []
    )
  end

  # Form MPR Par geste détaillé (non utilisé dans la vue simplifiée actuelle).
  def travaux_params
    params.require(:property).permit(
      :surface_ite, :surface_iti, :surface_sarking,
      :surface_combles_perdus, :surface_toiture_terrasse, :surface_plancher_bas,
      :nb_parois_vitrees,
      :pac_air_eau, :pac_geothermique,
      :chauffe_eau_thermo, :chauffe_eau_solaire,
      :systeme_solaire_combine, :pvt_eau,
      :poele_buches, :poele_granules, :insert_foyer,
      :raccordement_reseau_chaleur, :depose_fioul,
      :vmc_double_flux, :audit_energetique
    )
  end

  # Form simple : 7 macro-postes à cocher (card Rénovation énergétique)
  # + dpe_target (cible DPE positionnée via le slider JS).
  def travaux_selection_params
    params.require(:property).permit(
      :isolation_toiture, :isolation_murs, :isolation_plancher_bas,
      :chauffage, :chauffe_eau, :vmc, :menuiseries,
      :dpe_target
    )
  end
end

