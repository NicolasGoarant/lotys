module Admin
  class LocalAidSchemesController < ApplicationController
    before_action :authenticate_user!
    before_action :require_admin!
    before_action :set_scheme, only: [:show, :edit, :update, :destroy, :toggle_active]

    def index
      @schemes = LocalAidScheme.order(:territory, :aid_type)
    end

    def show; end
    def new
      @scheme = LocalAidScheme.new(active: true)
    end

    def create
      @scheme = LocalAidScheme.new(scheme_params)
      if @scheme.save
        redirect_to admin_local_aid_schemes_path, notice: "Dispositif créé."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit; end

    def update
      if @scheme.update(scheme_params)
        redirect_to admin_local_aid_schemes_path, notice: "Dispositif mis à jour."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @scheme.destroy
      redirect_to admin_local_aid_schemes_path, notice: "Dispositif supprimé."
    end

    def toggle_active
      @scheme.update!(active: !@scheme.active)
      redirect_to admin_local_aid_schemes_path,
                  notice: "Dispositif #{@scheme.active? ? 'activé' : 'désactivé'}."
    end

    private

    def set_scheme
      @scheme = LocalAidScheme.find(params[:id])
    end

    def require_admin!
      redirect_to root_path, alert: "Accès non autorisé." unless current_user.admin?
    end

    def scheme_params
      params.require(:local_aid_scheme).permit(
        :name, :territory, :aid_type,
        :rate_tres_modeste, :rate_modeste, :rate_intermediaire, :rate_superieur,
        :max_tres_modeste, :max_modeste, :max_intermediaire, :max_superieur,
        :conditions_text, :warning_text,
        :contact_name, :contact_url, :source_url, :source_label,
        :valid_from, :valid_until, :active,
        zipcodes: [], property_types: []
      )
    end
  end
end
