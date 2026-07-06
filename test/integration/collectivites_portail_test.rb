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

    # Anti-régression : aucun fragment de commentaire ERB ne doit fuiter
    # dans le HTML rendu du portail (même risque que sur properties/show).
    refute_match(/-%>/, response.body,
      "Un délimiteur ERB fermant '-%>' apparaît en texte visible sur le portail")
    refute_match(/CSS invalide/, response.body,
      "Un fragment de commentaire ERB (« CSS invalide ») a fuité sur le portail")
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

  # ── C5 : branding visuel + CTA vers formulaire ────────────────────────

  test "bandeau utilise primary_color de la collectivité" do
    setup_grand_nancy
    get "/collectivites/grand-nancy"
    # La primary_color apparaît dans le style inline du bandeau et du CTA.
    assert_match(/#0066a1/, response.body,
      "primary_color (#0066a1) doit apparaître dans le rendu — branding EPCI")
  end

  test "welcome_text rendu quand présent" do
    setup_grand_nancy
    get "/collectivites/grand-nancy"
    assert_select "#welcome-text"
    assert_match "Bienvenue", response.body
  end

  test "logo pas attaché → initiales rendues sur fond blanc en fallback" do
    setup_grand_nancy
    get "/collectivites/grand-nancy"
    assert_select "#collectivite-initiales", { count: 1 },
      "Fallback initiales quand aucun logo attaché (permet la démo sans logo officiel)"
    assert_select "#collectivite-logo", { count: 0 }
    # Initiales : "Métropole du Grand Nancy" → "MDGN"
    assert_match "MDGN", response.body
  end

  test "CTA link pointe vers /properties/new?collectivite=grand-nancy" do
    setup_grand_nancy
    get "/collectivites/grand-nancy"
    cta = css_select("a#cta-new-property").first
    assert cta, "CTA 'Commencer' doit exister"
    assert_equal new_property_path(collectivite: "grand-nancy"), cta["href"],
      "Le CTA doit pré-paramétrer le formulaire avec le slug (rattachement C6)"
  end

  # ── C7 : SEO / partage social ─────────────────────────────────────────

  test "portail : title HTML contient le nom de la collectivité" do
    setup_grand_nancy
    get "/collectivites/grand-nancy"
    title = css_select("title").first
    assert title
    assert_match "Métropole du Grand Nancy", title.text
    assert_match "Lauze", title.text, "Garde 'Lauze' pour la reconnaissance de marque"
  end

  test "portail : meta description = welcome_text (partage social)" do
    setup_grand_nancy
    get "/collectivites/grand-nancy"
    assert_select "meta[name='description'][content*='Bienvenue']"
  end

  test "portail sans logo attaché : pas de meta og:image (fallback layout)" do
    setup_grand_nancy
    get "/collectivites/grand-nancy"
    # Aucun logo attaché → pas d'og:image spécifique. Le partage social
    # tombera sur les defaults du site (favicon, etc.).
    assert_select "meta[property='og:image']", { count: 0 }
  end

  # ── Non-régression du parcours public (sans slug) ─────────────────────

  test "GET / (home) rend toujours 'Lauze' comme title (fallback layout inchangé)" do
    get "/"
    assert_select "title", "Lauze"
  end

  test "GET /properties/new sans slug : parcours nominal inchangé, aucun rattachement" do
    get "/properties/new"
    assert_response :success
    assert_select "input[type=hidden][name='property[collectivite_id]']", { count: 0 }
  end
end
