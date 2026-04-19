class ApplicationController < ActionController::Base
  layout :layout_by_resource

  # Callback global : quand l'utilisateur vient de s'inscrire ou de se connecter,
  # on vérifie s'il y a un bien "en attente" dans la session (créé via le
  # formulaire public AVANT authentification) et on le persiste pour lui.
  #
  # IMPORTANT : on restreint le callback aux controllers Devise SessionsController
  # et RegistrationsController pour éviter qu'il tourne sur chaque action du site
  # (un `after_action` global sur ApplicationController serait déclenché sur
  # n'importe quelle requête GET/POST du site).
  after_action :save_pending_property,
               if: -> { devise_session_or_registration_create? }

  def layout_by_resource
    devise_controller? ? "devise" : "application"
  end

  private

  # Détecte si l'action courante est une création de session Devise (sign-in)
  # ou une inscription (sign-up). Dans les deux cas, current_user vient juste
  # d'être défini et on peut persister le bien en attente.
  def devise_session_or_registration_create?
    return false unless params[:action] == "create"
    return false unless devise_controller?
    %w[sessions registrations].include?(params[:controller].to_s.split("/").last)
  end

  # Crée le bien précédemment saisi (dans le flow public non connecté) et
  # déclenche l'analyse IA, comme le ferait PropertiesController#create.
  # Sans ce déclenchement, l'utilisateur se retrouverait avec un bien vide
  # sans aucune analyse — bug historique du flow "register-then-save".
  def save_pending_property
    return unless user_signed_in?
    return unless session[:pending_property].present?

    attrs = session.delete(:pending_property)

    # Respecte la même limite que PropertiesController#create.
    if current_user.properties.count >= 3
      flash[:alert] = "Votre bien n'a pas pu être enregistré : limite de 3 biens par compte atteinte."
      return
    end

    property = current_user.properties.build(attrs)
    property.status = :analyzing

    if property.save
      PropertyAnalysisJob.perform_later(property.id)
      flash[:notice] = "Votre bien a été enregistré et l'analyse est en cours."
    else
      # Cas rare : validation Property échoue. On prévient l'utilisateur
      # sans casser le flow de connexion/inscription.
      flash[:alert] = "Impossible d'enregistrer le bien en attente : #{property.errors.full_messages.join(', ')}"
    end
  rescue StandardError => e
    # Protection ultime : aucune erreur ici ne doit casser la session Devise.
    Rails.logger.error "[save_pending_property] #{e.class}: #{e.message}"
    flash[:alert] = "Une erreur est survenue lors de l'enregistrement de votre bien."
  end
end
