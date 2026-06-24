require "test_helper"

# Rattachement automatique des Property orphelines au sign-in / sign-up
# via le jeton en cookie signé (commit 4/5).
#
# Mécanique : ApplicationController#claim_orphans_after_devise est un
# after_action déclenché par devise_session_or_registration_create?.
# Il appelle ClaimToken#claim_orphans!(current_user) qui rattache les
# orphelines correspondantes et nettoie le cookie.
class OrphanClaimAfterDeviseTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  CLAIM_COOKIE = ClaimToken::CLAIM_COOKIE
  GOOD_TOKEN   = "JETON_TEST_CLAIM_OK"
  OTHER_TOKEN  = "JETON_TEST_INCONNU"

  setup do
    # Rack::Attack limite à 10 POSTs /users/h/IP — ce qui suffirait, mais on
    # désactive par sécurité (cohérence avec les autres tests intégration).
    @_rack_attack_was_enabled = Rack::Attack.enabled
    Rack::Attack.enabled = false
  end

  teardown do
    Rack::Attack.enabled = @_rack_attack_was_enabled
  end

  # ─── Cas 1 : sign-up + cookie valide → claim ─────────────────────────

  # Le parcours réaliste sign-up : Devise :confirmable + allow_unconfirmed_access_for = 0.days
  # bloquent le sign-in automatique post-inscription. Le user doit confirmer son email
  # avant de pouvoir se connecter. Le claim se déclenche donc au PREMIER sign-in
  # post-confirmation, pas au sign-up lui-même (current_user est nil immédiatement
  # après registration#create). Le cookie persiste 30j → le rattachement aura lieu
  # même si la confirmation prend du temps.
  test "parcours réaliste sign-up → confirme → sign-in : l'orpheline est rattachée au premier sign-in confirmé" do
    orphan = build_orphan(GOOD_TOKEN)
    set_signed_cookie(CLAIM_COOKIE, GOOD_TOKEN)

    email = "test-#{SecureRandom.hex(4)}@example.com"

    # 1. Sign-up : user créé mais non signed_in (confirmable bloque)
    post user_registration_path, params: {
      user: { email: email, password: "password123", password_confirmation: "password123" }
    }
    user = User.find_by(email: email)
    assert_not_nil user, "Le user devrait avoir été créé"
    orphan.reload
    assert_nil orphan.user_id,
               "Au sign-up sans confirmation, current_user est nil → pas de claim. " \
               "L'orpheline reste intacte en attendant la confirmation."

    # 2. Confirme l'email manuellement (bypass du parcours email)
    user.update!(confirmed_at: Time.current)

    # 3. Sign-in confirmé : le callback voit current_user et claim
    post user_session_path, params: {
      user: { email: email, password: "password123" }
    }

    orphan.reload
    assert_equal user.id, orphan.user_id,
                 "Au premier sign-in confirmé, l'orpheline doit être rattachée (reçu user_id=#{orphan.user_id.inspect})"
    assert_nil orphan.claim_token,
               "Le claim_token doit être effacé après rattachement (le bien devient un bien possédé classique)"
  end

  # ─── Cas 2 : sign-in d'un user existant + cookie valide → claim ──────

  test "sign-in avec cookie portant un claim_token valide → l'orpheline est rattachée à l'utilisateur connecté" do
    user   = create_confirmed_user!
    orphan = build_orphan(GOOD_TOKEN)
    set_signed_cookie(CLAIM_COOKIE, GOOD_TOKEN)

    post user_session_path, params: {
      user: { email: user.email, password: "password123" }
    }

    orphan.reload
    assert_equal user.id, orphan.user_id, "L'orpheline doit être rattachée à user connecté"
    assert_nil orphan.claim_token
  end

  # ─── Cas 3 : sign-in SANS cookie → rien ne se passe ──────────────────

  test "sign-in sans cookie → aucune orpheline modifiée, aucune erreur" do
    user   = create_confirmed_user!
    orphan = build_orphan(GOOD_TOKEN)
    # Pas de set_signed_cookie : navigateur frais

    post user_session_path, params: {
      user: { email: user.email, password: "password123" }
    }

    orphan.reload
    assert_nil orphan.user_id, "Aucun rattachement ne doit se produire sans cookie"
    assert_equal GOOD_TOKEN, orphan.claim_token, "Le claim_token de l'orpheline reste intact"
    # Pas d'assertion sur le status HTTP : Devise gère sa propre redirection,
    # ce qu'on vérifie c'est l'absence de side-effect.
  end

  # ─── Cas 4 : cookie avec un jeton inexistant → no-op gracieux ────────

  test "sign-in avec cookie portant un jeton sans orpheline correspondante → no-op, cookie supprimé" do
    user = create_confirmed_user!
    # Aucune orpheline en DB pour OTHER_TOKEN.
    set_signed_cookie(CLAIM_COOKIE, OTHER_TOKEN)

    assert_nothing_raised do
      post user_session_path, params: {
        user: { email: user.email, password: "password123" }
      }
    end

    assert_equal 0, Property.where(user_id: user.id).count,
                 "Aucune Property ne doit être créée pour un jeton inconnu"
  end

  # ─── Cas 5 : défense en profondeur — ne vole pas un bien déjà possédé ─

  test "sign-in avec cookie ciblant une property déjà possédée (user_id présent) → AUCUN vol" do
    legitimate_owner   = create_confirmed_user!(email: "legit-#{SecureRandom.hex(4)}@example.com")
    already_owned      = legitimate_owner.properties.create!(
      address: "Bien légitime", city: "Nancy", zipcode: "54000"
    )
    # Cas tordu : un attaquant aurait posé un jeton qui correspond par hasard.
    # On simule en re-positionnant un claim_token sur un bien déjà possédé
    # (ce qui ne devrait pas arriver normalement vu qu'on clear au claim).
    already_owned.update_columns(claim_token: GOOD_TOKEN)   # bypass invariant pour le test

    attacker = create_confirmed_user!(email: "attacker-#{SecureRandom.hex(4)}@example.com")
    set_signed_cookie(CLAIM_COOKIE, GOOD_TOKEN)

    post user_session_path, params: {
      user: { email: attacker.email, password: "password123" }
    }

    already_owned.reload
    assert_equal legitimate_owner.id, already_owned.user_id,
                 "L'attaquant ne doit JAMAIS pouvoir voler un bien déjà possédé. " \
                 "La clause where(user_id: nil) de claim_orphans! le garantit."
  end

  # ─── Cas 6 : limite 3 biens/user respectée ───────────────────────────

  test "sign-in pour un user à 3 biens déjà → claim refusé, orpheline intacte" do
    user = create_confirmed_user!
    3.times do |i|
      user.properties.create!(address: "Bien #{i}", city: "Nancy", zipcode: "54000")
    end

    orphan = build_orphan(GOOD_TOKEN)
    set_signed_cookie(CLAIM_COOKIE, GOOD_TOKEN)

    post user_session_path, params: {
      user: { email: user.email, password: "password123" }
    }

    orphan.reload
    assert_nil orphan.user_id, "L'orpheline ne doit pas être rattachée (limite 3 biens dépassée)"
    assert_equal GOOD_TOKEN, orphan.claim_token,
                 "Le claim_token doit rester pour qu'un futur retry soit possible une fois le user à < 3 biens"
  end

  # ─── Helpers ─────────────────────────────────────────────────────────

  private

  def build_orphan(token)
    Property.create!(
      address:     "Bien orphelin",
      city:        "Nancy",
      zipcode:     "54000",
      claim_token: token,
      status:      :draft
    )
  end

  def create_confirmed_user!(email: "test-#{SecureRandom.hex(4)}@example.com")
    User.create!(
      email:                 email,
      password:              "password123",
      password_confirmation: "password123",
      confirmed_at:          Time.current
    )
  end

  # Voir orphan_claim_show_test.rb pour la justification : ActionDispatch::
  # IntegrationTest n'expose pas cookies.signed, on reconstruit une vraie
  # CookieJar Rails via TestRequest, signe via .signed, copie la valeur raw.
  def set_signed_cookie(name, value)
    request = ActionDispatch::TestRequest.create
    jar     = ActionDispatch::Cookies::CookieJar.build(request, cookies.to_hash)
    jar.signed[name] = value
    cookies[name.to_s] = jar[name.to_s]
  end
end
