require "test_helper"

# Lecture d'un bien orphelin via le jeton en cookie signé (commit 2/5).
#
# Trois voies d'autorisation dans set_property_for_read :
#   1. propriétaire connecté → son bien (régression #5)
#   2. orpheline + claim_token du cookie signé matche → autorisée (cas 1)
#   3. fallback Property.published.find(id) → visible par tous (régression #4)
#
# Garde-fous critiques :
#   - cas 2 : un navigateur SANS cookie ne doit PAS voir l'orpheline
#   - cas 3 : un navigateur avec un AUTRE cookie ne doit pas non plus
class OrphanClaimShowTest < ActionDispatch::IntegrationTest
  CLAIM_COOKIE = ClaimToken::CLAIM_COOKIE
  GOOD_TOKEN   = "JETON_TEST_BIEN"
  OTHER_TOKEN  = "JETON_TEST_AUTRE"

  setup do
    # Orpheline draft directement en DB. user: nil, claim_token: GOOD_TOKEN.
    # Le bien passe l'invariant #rattachable parce qu'il porte un jeton.
    @orphan = Property.create!(
      address:     "14 rue des Tilleuls",
      city:        "Vandœuvre-lès-Nancy",
      zipcode:     "54500",
      claim_token: GOOD_TOKEN,
      status:      :draft
    )
  end

  # ─── Cas 1 : bon cookie → 200 ────────────────────────────────────────

  test "navigateur avec le bon claim_token en cookie → GET /properties/:id de l'orpheline → 200" do
    set_signed_cookie(CLAIM_COOKIE, GOOD_TOKEN)

    get property_path(@orphan)
    assert_response :success,
                    "Le bon cookie signé devrait débloquer l'accès à l'orpheline, reçu status=#{response.status}, location=#{response.location.inspect}"
  end

  # ─── Cas 2 : aucun cookie → redirect (pas 200) ───────────────────────

  test "navigateur sans cookie → GET /properties/:id de l'orpheline → redirect (l'orpheline ne fuit pas)" do
    get property_path(@orphan)

    assert_response :redirect,
                    "Sans cookie, l'orpheline doit être invisible (redirect), reçu status=#{response.status}"
    assert_redirected_to root_path
  end

  # ─── Cas 3 : cookie avec un autre jeton → redirect ───────────────────

  test "navigateur avec un cookie contenant un autre claim_token → redirect" do
    set_signed_cookie(CLAIM_COOKIE, OTHER_TOKEN)

    get property_path(@orphan)
    assert_response :redirect,
                    "Un jeton qui ne matche pas ne doit JAMAIS donner accès, reçu status=#{response.status}"
    assert_redirected_to root_path
  end

  # ─── Régression cas 4 : published reste lisible par tous ─────────────

  test "régression : un bien published reste lisible par un visiteur anonyme (sans cookie)" do
    owner = create_confirmed_user!
    published = owner.properties.create!(
      address:              "1 rue Publiée",
      city:                 "Nancy",
      zipcode:              "54000",
      surface:              80,
      dpe_class:            "D",
      property_type:        "maison",
      construction_year:    1970,
      status:               :published,
      # C2 : publication conditionnée à la confirmation d'adresse.
      address_source:       "manuel",
      address_confirmed_at: Time.current
    )

    # Pas de sign_in, pas de cookie : visiteur strictement anonyme.
    get property_path(published)
    assert_response :success,
                    "Le fallback Property.published doit rester intact pour les visiteurs anonymes, reçu status=#{response.status}"
  end

  # ─── Régression cas 5 : propriétaire reste lisible par son propriétaire ─

  test "régression : un bien possédé reste lisible par son propriétaire connecté" do
    owner = create_confirmed_user!
    owned = owner.properties.create!(
      address: "2 rue Possédée",
      city:    "Nancy",
      zipcode: "54000",
      status:  :draft   # même draft, le propriétaire passe
    )

    sign_in owner
    get property_path(owned)
    assert_response :success,
                    "Le propriétaire connecté doit toujours pouvoir lire son bien, même draft, reçu status=#{response.status}"
  end

  # ─── Helpers ─────────────────────────────────────────────────────────

  private

  include Devise::Test::IntegrationHelpers

  # Écrit un cookie signé dans la session d'intégration. Le ActionDispatch::
  # IntegrationTest n'expose pas cookies.signed directement (sa jar est un
  # Rack::Test::CookieJar simple). On reconstruit une vraie CookieJar Rails
  # à partir d'une TestRequest, on y écrit via .signed (qui chiffre/signe
  # avec la clé secrète de l'app), puis on copie la valeur raw signée dans
  # le jar du test — le contrôleur la décodera normalement via cookies.signed.
  def set_signed_cookie(name, value)
    request = ActionDispatch::TestRequest.create
    jar     = ActionDispatch::Cookies::CookieJar.build(request, cookies.to_hash)
    jar.signed[name] = value
    cookies[name.to_s] = jar[name.to_s]
  end

  def create_confirmed_user!(email: "test-#{SecureRandom.hex(4)}@example.com")
    User.create!(
      email:                 email,
      password:              "password123",
      password_confirmation: "password123",
      confirmed_at:          Time.current
    )
  end
end
