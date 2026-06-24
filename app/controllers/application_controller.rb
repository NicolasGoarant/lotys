class ApplicationController < ActionController::Base
  include ClaimToken

  layout :layout_by_resource

  # Callback global : quand l'utilisateur vient de s'inscrire ou de se
  # connecter, on rattache à son compte toute Property orpheline dont le
  # claim_token est dans son cookie signé. Remplace l'ancien mécanisme
  # session[:pending_property] qui passait par un hash d'attributs — la
  # Property est maintenant déjà en DB depuis la création anonyme (commit 3).
  #
  # IMPORTANT : on restreint le callback aux controllers Devise SessionsController
  # et RegistrationsController pour éviter qu'il tourne sur chaque action du site
  # (un `after_action` global sur ApplicationController serait déclenché sur
  # n'importe quelle requête GET/POST du site).
  after_action :claim_orphans_after_devise,
               if: -> { devise_session_or_registration_create? }

  def layout_by_resource
    devise_controller? ? "devise" : "application"
  end

  private

  # Détecte si l'action courante est une création de session Devise (sign-in)
  # ou une inscription (sign-up). Dans les deux cas, current_user vient juste
  # d'être défini et on peut tenter le rattachement.
  def devise_session_or_registration_create?
    return false unless params[:action] == "create"
    return false unless devise_controller?
    %w[sessions registrations].include?(params[:controller].to_s.split("/").last)
  end

  # Rattache au compte les orphelines portées par le cookie. Tout est
  # délégué à ClaimToken#claim_orphans! (DB + logs + cleanup cookie).
  # Le rescue garantit qu'aucune erreur applicative ne casse le flow
  # Devise — l'utilisateur reste connecté même si le claim échoue.
  def claim_orphans_after_devise
    return unless user_signed_in?

    claimed = claim_orphans!(current_user)
    if claimed.any?
      flash[:notice] = if claimed.size == 1
        "Votre bien a été rattaché à votre compte."
      else
        "#{claimed.size} biens ont été rattachés à votre compte."
      end
    end
  rescue StandardError => e
    Rails.logger.error("[claim_orphans_after_devise] #{e.class}: #{e.message}")
    # Pas de flash[:alert] ici : on ne veut pas pourrir l'écran d'accueil
    # post-login de l'utilisateur pour une erreur de rattachement. Le bien
    # reste en DB avec son claim_token, récupérable plus tard si besoin.
  end
end
