require "test_helper"

# Garantit qu'après avoir cliqué le lien de confirmation Devise, l'utilisateur
# est directement connecté et renvoyé à l'accueil avec un flash de bienvenue,
# au lieu d'être redirigé vers /users/sign_in pour retaper son mot de passe.
#
# Comportement assuré par Users::ConfirmationsController#after_confirmation_path_for
# (surcharge de Devise::ConfirmationsController).
class UserConfirmationAutoSigninTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  test "GET du lien de confirmation : user confirmé, signed_in et redirigé vers root_path avec flash de bienvenue" do
    # Génère un raw token + son hash : la DB stocke le hash, l'URL transporte le raw.
    raw, hashed = Devise.token_generator.generate(User, :confirmation_token)

    user = User.create!(
      email:                 "confirme-#{SecureRandom.hex(4)}@example.com",
      password:              "password123",
      password_confirmation: "password123",
      confirmation_token:    hashed,
      confirmation_sent_at:  Time.current
    )
    assert_nil user.confirmed_at, "Sanity : le user doit partir non confirmé"

    get user_confirmation_path(confirmation_token: raw)

    assert_redirected_to root_path
    assert_not_nil user.reload.confirmed_at, "L'email doit être confirmé après le GET"

    # signed_in? : warden expose l'user authentifié sur l'env de la dernière requête.
    warden_user = request.env["warden"].user
    assert_equal user.id, warden_user&.id,
                 "L'utilisateur doit être automatiquement connecté après confirmation"

    follow_redirect!
    assert_response :success
    assert_match "Bienvenue sur Lauze", flash[:notice].to_s
  end
end
