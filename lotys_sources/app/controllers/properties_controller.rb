class PropertiesController < ApplicationController
  before_action :authenticate_user!, except: [:index, :new, :create, :show]
  before_action :set_property, only: [:show, :edit, :update, :destroy, :analyze, :publish, :unpublish, :preview, :update_income_bracket]

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
      @aid_result = AidCalculatorService.new(@property).call
    end
  end

  def new
    @property = Property.new
  end

  def create
    if user_signed_in?
      @property = current_user.properties.build(property_params)
      @property.status = :analyzing
      if @property.save
        attach_uploaded_documents
        run_analysis(@property)
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
    run_analysis(@property)
    redirect_to @property, notice: "Analyse relancée avec succès."
  end

  def publish
    @property.update(status: :published)
    redirect_to @property, notice: "Votre dossier est maintenant visible par les prestataires."
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

  def update_income_bracket
    @property.update(income_bracket: params[:income_bracket])
    @aid_result = AidCalculatorService.new(@property).call
    # Turbo Frame redessine uniquement l'étape 3
    render partial: "properties/aid_result", locals: { property: @property, aid_result: @aid_result }
  end

  def prestataire
    @property = Property.find(params[:id])
    unless @property.published? || @property.analyzed?
      redirect_to root_path, alert: "Ce dossier n'est pas disponible."
    end
    if user_signed_in? && current_user == @property.user
      redirect_to property_path(@property)
    end
  end

  private

  def run_analysis(property)
    property.update(status: :analyzing)
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

  # Sync automatique des champs depuis le JSON d'analyse
  # Évite à l'utilisateur de ressaisir ce que l'IA a déjà calculé
  def sync_analysis_fields(property)
    return unless property.analysis&.content.present?
    parsed = JSON.parse(property.analysis.content) rescue nil
    return unless parsed

    updates = {}

    # dpe_target : copié depuis energie.dpe_cible si non renseigné
    if property.dpe_target.blank?
      dpe_cible = parsed.dig("energie", "dpe_cible")&.upcase
      updates[:dpe_target] = dpe_cible if dpe_cible.present? && %w[A B C D E F G].include?(dpe_cible)
    end

    # dpe_class : depuis energie.dpe_estime si non renseigné
    if property.dpe_class.blank?
      dpe_estime = parsed.dig("energie", "dpe_estime")&.upcase
      updates[:dpe_class] = dpe_estime if dpe_estime.present? && %w[A B C D E F G].include?(dpe_estime)
    end

    property.update(updates) if updates.any?
    Rails.logger.info("sync_analysis_fields: #{updates.keys.join(', ')}")
  rescue => e
    Rails.logger.error("sync_analysis_fields failed: #{e.message}")
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

  def set_property
    if user_signed_in? && current_user.properties.exists?(params[:id])
      @property = current_user.properties.find(params[:id])
    else
      @property = Property.published.find(params[:id])
    end
  end

  def property_params
    params.require(:property).permit(
      :address, :city, :zipcode, :surface, :property_type,
      :construction_year, :dpe_class, :nb_rooms, :nb_lots,
      :is_copropriete, :description, :vacant, :source,
      :vacancy_duration, :vacancy_reason, :dpe_target, :income_bracket
    )
  end
end
