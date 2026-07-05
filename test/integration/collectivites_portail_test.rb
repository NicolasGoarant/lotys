require "test_helper"

# Tests d'intégration du portail collectivité (C4 controller/route).
# La vue complète (C5) et le rattachement des biens (C6) sont testés
# dans leurs commits respectifs.
class CollectivitesPortailTest < ActionDispatch::IntegrationTest
  def setup_grand_nancy(active: true)
    Collectivite.create!(
      name:          "Métropole du Grand Nancy",
      slug:          "grand-nancy",
      primary_color: "#0066a1",
      welcome_text:  "Bienvenue",
      insee_codes:   %w[54395 54547],  # Nancy + Vandœuvre
      active:        active
    )
  end

  # ── Accès ─────────────────────────────────────────────────────────────

  test "GET /collectivites/grand-nancy actif → 200 et rend le nom" do
    setup_grand_nancy
    get "/collectivites/grand-nancy"
    assert_response :success
    assert_match "Métropole du Grand Nancy", response.body
    assert_select "#collectivite-portail[data-slug='grand-nancy']"
  end

  test "GET /collectivites/<slug inconnu> → redirect vers /collectivites avec alert" do
    get "/collectivites/inconnue"
    assert_redirected_to collectivites_path
    follow_redirect!
    assert_match(/n'existe pas ou n'est plus disponible/, flash[:alert] || "")
  end

  test "GET /collectivites/<slug désactivé> → redirect (pas de leak actif/inactif)" do
    setup_grand_nancy(active: false)
    get "/collectivites/grand-nancy"
    assert_redirected_to collectivites_path
  end

  # ── Non-régression sur la route marketing ─────────────────────────────

  test "GET /collectivites sans slug → page marketing existante (non régressée)" do
    get "/collectivites"
    assert_response :success
    # La route marketing est déclarée AVANT la route portail.
    # Ce test verrouille cet ordre : sans lui, une régression de config
    # ferait matcher /collectivites → controller portail avec slug vide.
  end

  # ── Compteur biens ────────────────────────────────────────────────────

  test "compteur biens : ne compte QUE les biens analyzed/published sur les INSEE couverts" do
    setup_grand_nancy

    # Sur le territoire (Nancy) + analyzed → compté.
    Property.create!(
      address: "1", city: "Nancy", zipcode: "54000",
      claim_token: SecureRandom.hex(16),
      code_insee: "54395", status: :analyzed
    )
    # Sur le territoire (Vandœuvre) + published → compté.
    Property.create!(
      address: "2", city: "Vandœuvre", zipcode: "54500",
      claim_token: SecureRandom.hex(16),
      code_insee: "54547", status: :published,
      surface: 90, dpe_class: "D",
      address_confirmed_at: Time.current, address_source: "manuel"
    )
    # Sur le territoire + DRAFT → NON compté (pas encore passé par le pipeline).
    Property.create!(
      address: "3", city: "Nancy", zipcode: "54000",
      claim_token: SecureRandom.hex(16),
      code_insee: "54395", status: :draft
    )
    # Sur le territoire + ANALYZING → NON compté.
    Property.create!(
      address: "4", city: "Nancy", zipcode: "54000",
      claim_token: SecureRandom.hex(16),
      code_insee: "54395", status: :analyzing
    )
    # HORS territoire + analyzed → NON compté.
    Property.create!(
      address: "5", city: "Paris", zipcode: "75001",
      claim_token: SecureRandom.hex(16),
      code_insee: "75101", status: :analyzed
    )

    get "/collectivites/grand-nancy"
    assert_response :success

    node = css_select("#count-biens").first
    assert node
    assert_equal "2", node["data-count"],
      "Doit compter 2 biens (analyzed + published sur les INSEE couverts). Reçu : #{node["data-count"]}"
  end

  test "compteur biens : zéro par défaut si aucun bien" do
    setup_grand_nancy
    get "/collectivites/grand-nancy"
    assert_equal "0", css_select("#count-biens").first["data-count"]
  end
end
