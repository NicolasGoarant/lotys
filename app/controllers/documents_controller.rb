class DocumentsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_property

  def new
    @document = @property.documents.build
  end

  def create
    @document = @property.documents.build(document_params)
    if @document.save
      redirect_to @property, notice: "Document ajouté."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    @document = @property.documents.find(params[:id])
    @document.destroy
    redirect_to @property, notice: "Document supprimé."
  end

  private

  def set_property
    @property = current_user.properties.find(params[:property_id])
  end

  def document_params
    params.require(:document).permit(:document_type, :name, :file)
  end
end
  # DELETE /documents/1 or /documents/1.json
  def destroy
    @document.destroy!

    respond_to do |format|
      format.html { redirect_to documents_path, notice: "Document was successfully destroyed.", status: :see_other }
      format.json { head :no_content }
    end
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_document
      @document = Document.find(params[:id])
    end

    # Only allow a list of trusted parameters through.
    def document_params
      params.require(:document).permit(:property_id, :document_type, :name, :ai_summary, :processed)
    end
end
