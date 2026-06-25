class ApplicationController < ActionController::Base
  include ClaimToken

  # Exposé aux vues : permet à show.html.erb de discriminer
  # « tient le dossier complet » (propriétaire connecté OU détenteur du
  # claim_token en cookie) de « propriétaire connecté » (seul autorisé à
  # publier / modifier / supprimer).
  helper_method :claimable_by_browser?

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
  # délégué à ClaimToken#claim_orphans! qui renvoie un Hash structuré
  # { claimed: [...], left_behind: [...] } — politique « zéro perte » :
  # les orphelines au-delà de la limite restent en DB avec leur jeton,
  # et le cookie est réécrit pour qu'un futur sign-in (après libération
  # de place) reprenne le claim. Le flash informe l'utilisateur des
  # deux côtés — succès ET échecs — sans jamais mentir au singulier.
  #
  # Le rescue garantit qu'aucune erreur applicative ne casse le flow
  # Devise : l'utilisateur reste connecté même si le claim échoue.
  def claim_orphans_after_devise
    return unless user_signed_in?

    result      = claim_orphans!(current_user)
    claimed     = result[:claimed]
    left_behind = result[:left_behind]

    if claimed.any?
      flash[:notice] = claimed.size == 1 ?
        "Votre bien a été rattaché à votre compte." :
        "#{claimed.size} biens ont été rattachés à votre compte."
    end

    if left_behind.any?
      msg = if left_behind.size == 1
        "1 estimation n'a pas pu être rattachée : votre compte est limité " \
        "à #{ClaimToken::PROPERTY_LIMIT} biens. Libérez de la place puis " \
        "reconnectez-vous pour la récupérer."
      else
        "#{left_behind.size} estimations n'ont pas pu être rattachées : " \
        "votre compte est limité à #{ClaimToken::PROPERTY_LIMIT} biens. " \
        "Libérez de la place puis reconnectez-vous pour les récupérer."
      end
      flash[:alert] = msg
    end
  rescue StandardError => e
    Rails.logger.error("[claim_orphans_after_devise] #{e.class}: #{e.message}")
    # Pas de flash[:alert] ici : on ne veut pas pourrir l'écran d'accueil
    # post-login de l'utilisateur pour une erreur de rattachement. Le bien
    # reste en DB avec son claim_token, récupérable plus tard si besoin.
  end
end
