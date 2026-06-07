class PropertiesController < ApplicationController
  before_action :authenticate_user!, except: [:index, :new, :create, :show]

  # Lecture : propriétaire toujours, prestataire uniquement si le bien est publié.
  before_action :set_property_for_read, only: [:show, :preview]

  # Écriture : uniquement le propriétaire. Toute tentative par un autre user
  # (même connecté) renvoie vers /properties avec alerte. Protège contre la
  # suppression, modification, publication, dépublication d'un bien
  # qui n'appartient pas à l'utilisateur courant.
  before_action :set_property_for_write, only: [
    :edit, :update, :destroy, :analyze, :publish, :unpublish,
    :update_income_bracket, :update_dpe_target,
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
    if user_signed_in? && current_user == @property.user
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
      @aid_result = AidCalculatorService.new(
        @property,
        travaux_actifs: travaux_actifs_param
      ).call
    end
    respond_to do |format|
      format.html
      format.json { render json: { status: @property.status } }
    end
  end

  def new
    @property = Property.new
  end

  def create
    if user_signed_in?
      if current_user.properties.count >= 3
        redirect_to properties_path, alert: "Vous avez atteint la limite de 3 biens par compte."
        return
      end
      @property = current_user.properties.build(property_params)
      @property.status = :analyzing
      if @property.save
        attach_uploaded_documents
        PropertyAnalysisJob.perform_later(@property.id)
        redirect_to @property, notice: "Analyse complète générée."
      else
        render :new, status: :unprocessable_entity
      end
    else
      session[:pending_property] = property_params.to_h
      redirect_to new_user_registration_path, notice: "Créez votre compte pour sauvegarder votre dossier."
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

  def preview
  end

  def update_dpe_target
    @property.update(dpe_target: params[:dpe_target])
    redirect_to @property, notice: "Objectif DPE mis à jour."
  end

  # Change le profil revenus, recalcule les aides, et revient à la fiche
  # avec une ancre #aides pour que l'utilisateur reste scrollé sur la card Aides.
  def update_income_bracket
    @property.update(income_bracket: params[:income_bracket])
    redirect_to property_path(@property, anchor: "aides")
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

      doc_type = detect_document_type(file.original_filename)
      doc = @property.documents.build(
        document_type: doc_type,
        name: file.original_filename
      )
      doc.file.attach(file)
      doc.save
    end
  end

  def detect_document_type(filename)
    name = filename.downcase
    return :dpe             if name.include?("dpe")
    return :pv_ag           if name.include?("pv") || name.include?("coprop")
    return :titre_propriete if name.include?("attestation") || name.include?("acte") || name.include?("vente") || name.include?("aae")
    return :photo           if name.match?(/\.(jpg|jpeg|png|webp)$/)
    :autre
  end

  # Lecture :
  #   - propriétaire : accès à son bien quel que soit le status (draft inclus)
  #   - autres utilisateurs (y compris non connectés) : uniquement biens publiés
  # Ne fait PAS crasher sur user non connecté (bug précédent : current_user nil).
  def set_property_for_read
    if user_signed_in? && current_user.properties.exists?(id: params[:id])
      @property = current_user.properties.find(params[:id])
    else
      @property = Property.published.find(params[:id])
    end
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

  def property_params
    params.require(:property).permit(
      :address, :city, :zipcode, :surface, :property_type,
      :construction_year, :dpe_class, :nb_rooms, :nb_lots,
      :is_copropriete, :description, :vacant, :source,
      :vacancy_duration, :vacancy_reason, :dpe_target, :income_bracket,
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

