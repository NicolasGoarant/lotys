# Surcharge le ConfirmationsController de Devise pour qu'après avoir cliqué
# le lien de confirmation, l'utilisateur soit directement connecté et renvoyé
# à l'accueil, plutôt que rebondir sur /users/sign_in où il devrait retaper
# son mot de passe (comportement par défaut induit par
# allow_unconfirmed_access_for = 0.days dans config/initializers/devise.rb).
#
# Devise#show appelle set_flash_message!(:notice, :confirmed) AVANT
# after_confirmation_path_for : écraser flash[:notice] ici remplace donc le
# message générique par un message d'accueil Lauze.
class Users::ConfirmationsController < Devise::ConfirmationsController
  protected

  def after_confirmation_path_for(_resource_name, resource)
    sign_in(resource)
    flash[:notice] = "Bienvenue sur Lauze, votre compte est confirmé."
    root_path
  end
end
