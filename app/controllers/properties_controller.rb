class PropertiesController < ApplicationController
  before_action :authenticate_user!, except: [:index, :new, :create]
  before_action :set_property, only: [:show, :edit, :update, :destroy, :analyze, :publish]

  def index
    if user_signed_in?
      @properties = current_user.properties.order(created_at: :desc)
      render :index
    else
      redirect_to root_path
    end
  end

  def show
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
    property.update(status: :analyzed)
  end

def attach_uploaded_documents
  uploaded = params.dig(:property, :uploaded_files)
  return unless uploaded.present?

  Array(uploaded).each do |file|
    next unless file.respond_to?(:original_filename)

    ext = File.extname(file.original_filename).downcase
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
  return :dpe          if name.include?("dpe")
  return :pv_ag        if name.include?("pv") || name.include?("coprop")
  return :titre_propriete if name.include?("attestation") || name.include?("acte") || name.include?("vente") || name.include?("aae")
  return :photo        if name.match?(/\.(jpg|jpeg|png|webp)$/)
  :autre
end


  def set_property
    @property = current_user.properties.find(params[:id])
  end

  def property_params
    params.require(:property).permit(
      :address, :city, :zipcode, :surface, :property_type,
      :construction_year, :dpe_class, :nb_rooms, :nb_lots,
      :is_copropriete, :description, :vacant, :source,
      :vacancy_duration, :vacancy_reason
    )
  end
end
