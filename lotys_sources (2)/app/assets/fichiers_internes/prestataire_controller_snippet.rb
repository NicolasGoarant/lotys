# Ajouter dans config/routes.rb, dans le bloc resources :properties :
#
#   resources :properties do
#     member do
#       get :prestataire   # ← ajouter cette ligne
#       get :analyze, ...
#       ...
#     end
#   end
#
# ─────────────────────────────────────────────────────────────
# Ajouter dans app/controllers/properties_controller.rb :

  def prestataire
    @property = Property.find(params[:id])
    # Seuls les biens publiés ou analysés sont visibles par les prestataires
    unless @property.published? || @property.analyzed?
      redirect_to root_path, alert: "Ce dossier n'est pas disponible."
    end
    # Le propriétaire est redirigé vers sa propre show
    if user_signed_in? && current_user == @property.user
      redirect_to property_path(@property)
    end
  end
