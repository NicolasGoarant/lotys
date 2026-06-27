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

  # En auto-signant l'utilisateur ici, on court-circuite le flow historique
  # (POST /users/sign_in après confirmation). Or l'after_action
  # claim_orphans_after_devise d'ApplicationController est restreint aux
  # actions sessions#create / registrations#create — confirmations#show n'est
  # pas dans le périmètre. Sans rattrapage, le cookie claim_token survit à la
  # connexion sans jamais déclencher le rattachement. On invoque donc le
  # callback explicitement après sign_in (avec current_user défini), ce qui
  # réutilise toute la politique de claim (limite à PROPERTY_LIMIT, flash de
  # rattachement / left_behind) sans la dupliquer. Si une orpheline est
  # rattachée, claim_orphans_after_devise écrase flash[:notice] avec un
  # message plus informatif que le simple « Bienvenue » — ce qui est voulu.
  def after_confirmation_path_for(_resource_name, resource)
    sign_in(resource)
    flash[:notice] = "Bienvenue sur Lauze, votre compte est confirmé."
    claim_orphans_after_devise
    root_path
  end
end
