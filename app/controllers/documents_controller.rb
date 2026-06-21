class DocumentsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_property

  def new
    @document = @property.documents.build
  end

  def create
    saved = 0
    Array(params.dig(:document, :files)).each do |file|
      next unless file.respond_to?(:original_filename)
      doc = @property.documents.build(
        document_type: params.dig(:document, :document_type),
        name: file.original_filename
      )
      doc.file.attach(file)
      doc.save!
      saved += 1
    end

    if saved == 0
      @document = @property.documents.build
      flash.now[:alert] = "Veuillez sélectionner au moins un fichier."
      render :new, status: :unprocessable_entity and return
    end

    # Analyse déportée en tâche de fond (GoodJob) : la requête web rend la
    # main immédiatement après l'upload S3, sous les 30 s du routeur Heroku.
    # Le job exécute le pipeline complet (DocumentAnalysisService, extraction,
    # sync des champs) PUIS purge les fichiers — ce que le chemin synchrone
    # précédent ne faisait pas (docs non lus + non purgés).
    Analysis.where(property: @property).delete_all
    @property.update!(status: :analyzing)
    PropertyAnalysisJob.perform_later(@property.id)

    redirect_to @property, notice: "#{saved} document(s) ajouté(s) · Analyse IA en cours…"
  rescue => e
    @document = @property.documents.build
    flash.now[:alert] = "Erreur : #{e.message}"
    render :new, status: :unprocessable_entity
  end

  def destroy
    @document = @property.documents.find(params[:id])
    @document.destroy
    redirect_to property_path(@property, anchor: "documents"), notice: "Document supprimé."
  end

  private

  def set_property
    @property = current_user.properties.find(params[:property_id])
  end
end
