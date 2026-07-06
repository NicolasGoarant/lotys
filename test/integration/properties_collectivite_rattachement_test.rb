require "test_helper"
require "minitest/mock"
require_relative "../support/aid_rules_helper"

# Tests d'intégration C6 — rattachement d'un bien à une collectivité
# quand il est créé depuis un portail EPCI, et garde-fou "hors ressort"
# qui reset le rattachement si l'adresse confirmée sort du territoire.
class PropertiesCollectiviteRattachementTest < ActionDispatch::IntegrationTest
  include AidRulesHelper

  CLAIM_COOKIE = ClaimToken::CLAIM_COOKIE
  TOKEN        = "JETON_COLLECTIVITE_TEST"

  setup do
    seed_aid_rules!
    set_signed_cookie(CLAIM_COOKIE, TOKEN)
    @grand_nancy = Collectivite.create!(
      name:          "Métropole du Grand Nancy",
      slug:          "grand-nancy",
      primary_color: "#0066a1",
      welcome_text:  "Bienvenue",
      insee_codes:   %w[54395 54547],  # Nancy + Vandœuvre
      active:        true
    )
  end

  # ── new : chargement de @collectivite depuis params ───────────────────

  test "GET /properties/new?collectivite=grand-nancy → hidden_field collectivite_id posé" do
    get new_property_path(collectivite: "grand-nancy")
    assert_response :success

    assert_select "input[type=hidden][name='property[collectivite_id]'][value='#{@grand_nancy.id}']",
      { count: 1 },
      "Le hidden_field doit être rendu pour transmettre le rattachement au POST create"
  end

  test "GET /properties/new sans param collectivite → pas de hidden_field (parcours nominal)" do
    get new_property_path
    assert_response :success
    assert_select "input[type=hidden][name='property[collectivite_id]']", { count: 0 }
  end

  test "GET /properties/new?collectivite=<slug inconnu> → parcours nominal (pas de hidden_field, pas d'erreur)" do
    get new_property_path(collectivite: "portail-fictif")
    assert_response :success
    assert_select "input[type=hidden][name='property[collectivite_id]']", { count: 0 }
  end

  test "GET /properties/new?collectivite=<slug désactivé> → pas de hidden_field (portail éteint)" do
    @grand_nancy.update!(active: false)
    get new_property_path(collectivite: "grand-nancy")
    assert_response :success
    assert_select "input[type=hidden][name='property[collectivite_id]']", { count: 0 }
  end

  # ── create : rattachement effectif ────────────────────────────────────

  test "POST /properties avec collectivite_id → rattachement persisté" do
    post properties_path, params: {
      property: {
        address:         "1 rue de Test",
        city:            "Nancy",
        zipcode:         "54000",
        collectivite_id: @grand_nancy.id
      }
    }
    assert_response :redirect

    p = Property.last
    assert_equal @grand_nancy.id, p.collectivite_id,
      "Le rattachement doit être persisté depuis les property_params permit"
  end

  test "POST /properties SANS collectivite_id → parcours nominal, collectivite nil" do
    post properties_path, params: {
      property: { address: "1 rue de Test", city: "Nancy", zipcode: "54000" }
    }
    assert_nil Property.last.collectivite_id
  end

  # ── Garde-fou hors ressort dans confirm_address ───────────────────────

  def property_avec_detection(source: "dpe")
    p = Property.new(claim_token: TOKEN, collectivite: @grand_nancy)
    p.save(validate: false)
    p.documents.create!(document_type: :dpe, name: "dpe.pdf")
    p.update_columns(
      address_detected:  "12 rue du Haut-Rivage",
      city_detected:     "Malzéville",
      zipcode_detected:  "54220",
      address_source:    source
    )
    p
  end

  # BAN qui renvoie un code INSEE dans le ressort (Nancy).
  def ban_in_territory
    Struct.new(:body).new({
      "features" => [
        {
          "geometry"   => { "coordinates" => [6.19, 48.72] },
          "properties" => { "score" => 0.87, "citycode" => "54395" }  # Nancy
        }
      ]
    }.to_json)
  end

  # BAN qui renvoie un code INSEE HORS du ressort.
  def ban_off_territory
    Struct.new(:body).new({
      "features" => [
        {
          "geometry"   => { "coordinates" => [2.34, 48.85] },
          "properties" => { "score" => 0.87, "citycode" => "75101" }  # Paris
        }
      ]
    }.to_json)
  end

  test "confirm_address dans le ressort → collectivite_id CONSERVÉ" do
    p = property_avec_detection
    assert_equal @grand_nancy.id, p.collectivite_id

    HTTParty.stub :get, ->(*_args) { ban_in_territory } do
      post confirm_address_property_path(p), params: {
        property: { address: "1 rue de Test", city: "Nancy", zipcode: "54000" }
      }
    end
    p.reload

    assert_equal "54395", p.code_insee, "BAN a bien posé code_insee"
    assert_equal @grand_nancy.id, p.collectivite_id,
      "Bien dans le ressort → rattachement conservé"
  end

  test "confirm_address HORS ressort → collectivite_id RESET à NULL" do
    p = property_avec_detection
    assert_equal @grand_nancy.id, p.collectivite_id

    HTTParty.stub :get, ->(*_args) { ban_off_territory } do
      post confirm_address_property_path(p), params: {
        property: { address: "1 rue Parisienne", city: "Paris", zipcode: "75001" }
      }
    end
    p.reload

    assert_equal "75101", p.code_insee
    assert_nil p.collectivite_id,
      "Bien HORS ressort → rattachement retiré (principe 'pas de caution hors territoire')"
  end

  test "confirm_address bien SANS collectivite (parcours nominal) → no-op, rien de cassé" do
    # Bien créé sans rattachement, confirmation d'adresse standard.
    p = Property.new(claim_token: TOKEN, collectivite: nil)
    p.save(validate: false)
    p.documents.create!(document_type: :dpe, name: "dpe.pdf")

    HTTParty.stub :get, ->(*_args) { ban_in_territory } do
      post confirm_address_property_path(p), params: {
        property: { address: "1 rue de Test", city: "Nancy", zipcode: "54000" }
      }
    end
    assert_redirected_to property_path(p)

    p.reload
    assert_equal "54395", p.code_insee
    assert_nil p.collectivite_id, "Reste sans rattachement (aucun mis à jour)"
  end

  # ── reset_collectivite_if_off_territory! — tests unitaires du helper ─

  test "helper reset : no-op si collectivite_id nil" do
    p = Property.new(claim_token: TOKEN, collectivite: nil, code_insee: "54395")
    p.save(validate: false)
    refute p.reset_collectivite_if_off_territory!
    assert_nil p.collectivite_id
  end

  test "helper reset : no-op si code_insee blank (encore pas géocodé)" do
    p = Property.new(claim_token: TOKEN, collectivite: @grand_nancy, code_insee: nil)
    p.save(validate: false)
    refute p.reset_collectivite_if_off_territory!
    assert_equal @grand_nancy.id, p.collectivite_id,
      "Rattachement conservé tant que code_insee n'est pas encore posé (re-check plus tard)"
  end

  test "helper reset : dans le ressort → conservé, retour false" do
    p = Property.new(claim_token: TOKEN, collectivite: @grand_nancy, code_insee: "54395")
    p.save(validate: false)
    refute p.reset_collectivite_if_off_territory!
    assert_equal @grand_nancy.id, p.collectivite_id
  end

  test "helper reset : hors ressort → reset, retour true" do
    p = Property.new(claim_token: TOKEN, collectivite: @grand_nancy, code_insee: "75101")
    p.save(validate: false)
    assert p.reset_collectivite_if_off_territory!
    p.reload
    assert_nil p.collectivite_id
  end

  # ── C7 : badge portail sur la fiche du bien ──────────────────────────

  test "show : bien rattaché → badge collectivité affiché" do
    p = Property.new(
      claim_token: TOKEN,
      collectivite: @grand_nancy,
      address: "1 rue de Test", city: "Nancy", zipcode: "54000",
      code_insee: "54395", status: :analyzed
    )
    p.save!

    get property_path(p)
    assert_response :success
    assert_select "#collectivite-badge", { count: 1 }

    badge = css_select("#collectivite-badge").first
    # Libellé neutre : "Portail <nom>" — évite le doublon d'article
    # ("Analyse au titre du Métropole du Grand Nancy" en ancien libellé).
    assert_match "Portail Métropole du Grand Nancy", badge.text
    refute_match(/au titre du/, badge.text,
      "Anti-régression du libellé 'Analyse au titre du <nom>' qui doublait 'du'")
    # Lien vers le portail (traçabilité provenance).
    assert_equal collectivite_portail_path("grand-nancy"), badge["href"]
    # Primary_color EFFECTIVEMENT interpolée dans le style (anti-régression
    # du bug ERB #{…} rendu littéralement dans le HTML brut).
    style = badge["style"].to_s
    assert_match(/#0066a1/i, style,
      "primary_color doit apparaître dans le style rendu — sinon le badge s'affiche sans couleurs. " \
      "Style : #{style.inspect}")
    refute_match(/#\{/, style,
      'Aucune interpolation ERB "#{…}" littérale ne doit rester dans le style rendu')

    # Anti-régression : aucun fragment de commentaire ERB ne doit fuiter
    # dans le HTML rendu (bug d'un <%# … %> multi-ligne dont le corps
    # citait un %> et refermait le tag au mauvais endroit).
    refute_match(/CSS invalide/, response.body,
      "Un fragment de commentaire ERB (« CSS invalide ») a fuité dans le HTML rendu")
    refute_match(/-%>/, response.body,
      "Un délimiteur ERB fermant '-%>' apparaît en texte visible")
    refute_match(/badge sans couleurs/, response.body,
      "Un fragment de commentaire ERB (« badge sans couleurs ») a fuité dans le HTML rendu")
  end

  test "show : bien NON rattaché → aucun badge (parcours nominal)" do
    p = Property.new(
      claim_token: TOKEN,
      collectivite: nil,
      address: "1 rue de Test", city: "Nancy", zipcode: "54000",
      code_insee: "54395", status: :analyzed
    )
    p.save!

    get property_path(p)
    assert_response :success
    assert_select "#collectivite-badge", { count: 0 }
  end

  test "show : bien rattaché à une collectivité DÉSACTIVÉE → aucun badge (portail éteint)" do
    p = Property.new(
      claim_token: TOKEN, collectivite: @grand_nancy,
      address: "1 rue de Test", city: "Nancy", zipcode: "54000",
      code_insee: "54395", status: :analyzed
    )
    p.save!
    @grand_nancy.update!(active: false)

    get property_path(p)
    assert_response :success
    assert_select "#collectivite-badge", { count: 0 },
      "Un bien reste rattaché en base mais la collectivité est éteinte : pas de badge"
  end

  private

  def set_signed_cookie(name, value)
    request = ActionDispatch::TestRequest.create
    jar     = ActionDispatch::Cookies::CookieJar.build(request, cookies.to_hash)
    jar.signed[name] = value
    cookies[name.to_s] = jar[name.to_s]
  end
end
