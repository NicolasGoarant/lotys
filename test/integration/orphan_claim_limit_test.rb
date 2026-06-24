require "test_helper"

# Conformité à la POLITIQUE A — « zéro perte » au plafond 3 biens.
#
# Quand le rattachement ferait dépasser ClaimToken::PROPERTY_LIMIT, on :
#   1. claim jusqu'à la limite (ordre du cookie),
#   2. laisse les orphelines en surplus en DB avec leur claim_token intact,
#   3. RÉÉCRIT le cookie pour qu'il porte EXACTEMENT les jetons des
#      orphelines restées en attente (pas celles déjà claimées, leur
#      token a été nullifié),
#   4. informe l'utilisateur par flash sans mentir au singulier.
#
# Ce fichier remplace orphan_claim_limit_observation_test.rb. L'observation
# initiale (perte silencieuse) est documentée par git history.
class OrphanClaimLimitTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  CLAIM_COOKIE = ClaimToken::CLAIM_COOKIE
  TOKEN_A      = "JETON_LIMIT_A"
  TOKEN_B      = "JETON_LIMIT_B"

  setup do
    @_rack_attack_was_enabled = Rack::Attack.enabled
    Rack::Attack.enabled = false
  end

  teardown do
    Rack::Attack.enabled = @_rack_attack_was_enabled
  end

  # ─── 1. Plafond atteint au cours du claim : A passe, B en attente ────

  test "user à 2 biens + cookie [TOKEN_A, TOKEN_B] → A rattachée, B reste orpheline, cookie ne contient PLUS QUE TOKEN_B" do
    user = create_confirmed_user!
    user.properties.create!(address: "Bien 1", city: "Nancy", zipcode: "54000")
    user.properties.create!(address: "Bien 2", city: "Nancy", zipcode: "54000")

    orphan_a = build_orphan(TOKEN_A)
    orphan_b = build_orphan(TOKEN_B)
    set_signed_cookie(CLAIM_COOKIE, [TOKEN_A, TOKEN_B])

    post user_session_path, params: {
      user: { email: user.email, password: "password123" }
    }

    user.reload; orphan_a.reload; orphan_b.reload

    assert_equal 3, user.properties.count, "Le user doit atteindre la limite de 3 biens"

    assert_equal user.id, orphan_a.user_id, "Orphan A (1er du cookie) doit être rattaché"
    assert_nil   orphan_a.claim_token,      "Orphan A : claim_token clear après rattachement"

    assert_nil   orphan_b.user_id,    "Orphan B doit RESTER orpheline (limite atteinte)"
    assert_equal TOKEN_B, orphan_b.claim_token,
                 "Orphan B : claim_token PRÉSERVÉ pour permettre un futur retry"

    # Cookie : doit contenir UNIQUEMENT le token B, pas A (déjà claim) ni vide.
    remaining = read_signed_cookie(CLAIM_COOKIE)
    assert_equal TOKEN_B, remaining,
                 "Cookie doit être réécrit avec EXACTEMENT le token de l'orpheline en attente. " \
                 "Reçu : #{remaining.inspect}"
  end

  # ─── 2. Récupérabilité : libérer de la place permet de finir le claim ─

  test "récupérabilité : après suppression d'un bien possédé, re-sign-in rattache enfin l'orpheline restante" do
    user = create_confirmed_user!
    bien1 = user.properties.create!(address: "Bien 1", city: "Nancy", zipcode: "54000")
    user.properties.create!(address: "Bien 2", city: "Nancy", zipcode: "54000")

    orphan_a = build_orphan(TOKEN_A)
    orphan_b = build_orphan(TOKEN_B)
    set_signed_cookie(CLAIM_COOKIE, [TOKEN_A, TOKEN_B])

    # Premier sign-in : A claim, B en attente, cookie réécrit avec TOKEN_B.
    post user_session_path, params: {
      user: { email: user.email, password: "password123" }
    }
    orphan_b.reload
    assert_nil orphan_b.user_id, "Sanity : B doit encore être orpheline après le 1er sign-in"

    # Le user libère de la place en supprimant un de ses biens. On
    # bypass la route et on appelle destroy directement pour ne pas
    # dépendre du contrôleur (qui peut avoir ses propres rebonds).
    bien1.destroy

    # Sign-out explicite : sans ça, le 2nd POST user_session_path est
    # court-circuité par Devise (« already signed in ») → sessions#create
    # ne tourne pas → notre after_action ne fire pas.
    delete destroy_user_session_path

    # Re-sign-in : cookie contient encore TOKEN_B → B doit se rattacher.
    post user_session_path, params: {
      user: { email: user.email, password: "password123" }
    }

    user.reload; orphan_b.reload
    assert_equal user.id, orphan_b.user_id,
                 "Après libération de place, B doit enfin se rattacher au re-sign-in"
    assert_nil orphan_b.claim_token, "B : claim_token clear après rattachement effectif"

    remaining_after = read_signed_cookie(CLAIM_COOKIE)
    assert remaining_after.blank?,
           "Cookie doit être supprimé après le claim complet, reçu : #{remaining_after.inspect}"
  end

  # ─── 3. Cas nominal : 0 + 2 → tout rattaché, cookie vide, pas d'alerte ─

  test "cas nominal : user à 0 bien + 2 orphelines → les 2 rattachées, cookie vide, aucun flash de limite" do
    user = create_confirmed_user!

    orphan_a = build_orphan(TOKEN_A)
    orphan_b = build_orphan(TOKEN_B)
    set_signed_cookie(CLAIM_COOKIE, [TOKEN_A, TOKEN_B])

    post user_session_path, params: {
      user: { email: user.email, password: "password123" }
    }

    user.reload; orphan_a.reload; orphan_b.reload

    assert_equal 2, user.properties.count, "Les 2 orphelines doivent être rattachées"
    assert_equal user.id, orphan_a.user_id
    assert_equal user.id, orphan_b.user_id

    remaining = read_signed_cookie(CLAIM_COOKIE)
    assert remaining.blank?, "Cookie supprimé attendu (rien à reprendre), reçu : #{remaining.inspect}"

    # flash[:alert] ne doit PAS contenir le message de limite.
    assert_no_match(/limité à 3 biens/, flash[:alert].to_s,
                    "Aucun message de limite ne doit s'afficher quand tout est rattaché")
  end

  # ─── 4. Flash : message de limite affiché quand left_behind.any? ────

  test "flash : présence du message de limite sur la page post-login quand au moins 1 orpheline reste en attente" do
    user = create_confirmed_user!
    user.properties.create!(address: "Bien 1", city: "Nancy", zipcode: "54000")
    user.properties.create!(address: "Bien 2", city: "Nancy", zipcode: "54000")

    build_orphan(TOKEN_A)
    build_orphan(TOKEN_B)
    set_signed_cookie(CLAIM_COOKIE, [TOKEN_A, TOKEN_B])

    post user_session_path, params: {
      user: { email: user.email, password: "password123" }
    }

    # Suit la redirection pour voir le flash rendu dans la page de destination.
    follow_redirect!

    body = response.body
    # Note : l'apostrophe française est HTML-escapée en &#39; dans le body
    # rendu. On matche sur des fragments sans apostrophe pour rester
    # indifférent à l'encodage HTML.
    assert_match(/pas pu être rattachée/, body,
                 "Le message de limite doit être visible sur la page post-login")
    assert_match(/limité à 3 biens/, body,
                 "Le message doit nommer la limite de 3 biens")
    assert_match(/Libérez de la place/, body,
                 "Le message doit indiquer comment résoudre (libérer de la place + reconnexion)")
  end

  # ─── Helpers ─────────────────────────────────────────────────────────

  private

  def build_orphan(token)
    Property.create!(
      address: "Orpheline #{token}",
      city: "Nancy", zipcode: "54000",
      claim_token: token, status: :draft
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

  def set_signed_cookie(name, value)
    request = ActionDispatch::TestRequest.create
    jar     = ActionDispatch::Cookies::CookieJar.build(request, cookies.to_hash)
    jar.signed[name] = value
    cookies[name.to_s] = jar[name.to_s]
  end

  # Lecture de la valeur SIGNÉE actuelle du cookie après une requête.
  # On reconstruit une CookieJar Rails à partir du contenu raw exposé par
  # le jar de test et on la lit via .signed, qui déchiffre/vérifie avec
  # la clé secrète de l'app.
  def read_signed_cookie(name)
    request = ActionDispatch::TestRequest.create
    jar     = ActionDispatch::Cookies::CookieJar.build(request, cookies.to_hash)
    jar.signed[name]
  end
end
