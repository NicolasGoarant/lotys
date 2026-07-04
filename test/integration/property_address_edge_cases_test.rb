require "test_helper"
require "minitest/mock"
require_relative "../support/aid_rules_helper"

# ═══════════════════════════════════════════════════════════════════════
#   C7 — Tests conflit / échec BAN / non-régression stubs
#
#   Complète les tests des étapes précédentes (C3 pour l'extraction, C5
#   pour l'action confirm_address) sur les CAS LIMITES qui doivent rester
#   silencieusement gérés :
#
#     1. Conflit LLM (address_source null renvoyé par le prompt) : la
#        détection n'est PAS déposée → bandeau "aucune détection" pour
#        que l'utilisateur saisisse manuellement.
#
#     2. Échec BAN (timeout, exception réseau) : la confirmation reste
#        opérante — address_confirmed_at est posé, publication débloquée,
#        seul code_insee reste NULL (dégradation gracieuse).
#
#     3. BAN score faible (< MIN_INSEE_SCORE = 0.4) : lat/lng écrits,
#        code_insee non écrit — semantic voulue de GeocodingService pour
#        ne pas rattacher à la mauvaise commune.
#
#   Tous les tests stubent HTTParty.get via Minitest::Mock — aucun appel
#   réseau réel. Convention alignée sur C4/C5.
# ═══════════════════════════════════════════════════════════════════════
class PropertyAddressEdgeCasesTest < ActionDispatch::IntegrationTest
  include AidRulesHelper

  CLAIM_COOKIE = ClaimToken::CLAIM_COOKIE
  TOKEN        = "JETON_EDGE_CASES_TEST"

  setup do
    seed_aid_rules!
    set_signed_cookie(CLAIM_COOKIE, TOKEN)
  end

  # ── Property orpheline typique du parcours "documents sans adresse" ──
  def property_avec_doc
    p = Property.new(claim_token: TOKEN)
    p.save(validate: false)
    p.documents.create!(document_type: :dpe, name: "dpe.pdf")
    p
  end

  # ── Réponses BAN types ─────────────────────────────────────────────
  def ban_response_ok(score: 0.87)
    Struct.new(:body).new({
      "features" => [
        {
          "geometry"   => { "coordinates" => [6.19, 48.72] },
          "properties" => { "score" => score, "citycode" => "54339" }
        }
      ]
    }.to_json)
  end

  def ban_response_vide
    Struct.new(:body).new({ "features" => [] }.to_json)
  end

  # ─────────────────────────────────────────────────────────────────
  # 1. CONFLIT LLM — address_source null → aucune détection persistée
  # ─────────────────────────────────────────────────────────────────

  test "extraction LLM en conflit (address_source null) : pas de détection posée, bandeau saisie manuelle affiché" do
    # Reproduit le scénario "DPE et titre donnent des adresses différentes" :
    # le prompt instruit le LLM à répondre address_source=null dans ce cas
    # (cf. PropertyDataExtractorService prompt PRIORITÉ 3). update_property
    # ne dépose alors RIEN dans les colonnes _detected.
    p = property_avec_doc

    # Simule ce que ferait le service en interne — on court-circuite le
    # LLM en appelant directement update_property avec le trio + source=null.
    PropertyDataExtractorService.new(p).send(:update_property, {
      "address"        => "12 rue X",
      "city"           => "Nancy",
      "zipcode"        => "54000",
      "address_source" => nil  # LLM a détecté un conflit
    })
    p.reload

    assert_nil p.address_detected, "Conflit LLM → aucune détection déposée"
    assert_nil p.address_source

    # Vue : bandeau visible en mode "aucune détection"
    get property_path(p)
    assert_response :success
    assert_select "#confirm-address"
    assert_match(/n'avons pas pu déduire/i, response.body,
      "Sans détection, on doit voir le libellé de saisie manuelle")
  end

  test "saisie 100 % manuelle après conflit LLM : confirmation opère normalement" do
    p = property_avec_doc

    HTTParty.stub :get, ->(*_args) { ban_response_ok } do
      post confirm_address_property_path(p), params: {
        property: {
          address: "8 rue de la Craffe",
          city:    "Nancy",
          zipcode: "54000"
        }
      }
    end
    assert_redirected_to property_path(p)

    p.reload
    assert_equal "8 rue de la Craffe", p.address
    assert_equal "manuel",             p.address_source,
      "Saisie manuelle après aucune détection → source manuel"
    assert p.address_confirmed_at.present?
  end

  # ─────────────────────────────────────────────────────────────────
  # 2. ÉCHEC BAN — la confirmation reste opérante
  # ─────────────────────────────────────────────────────────────────

  test "BAN lève une exception (timeout, réseau) : confirmation reste OK, code_insee NULL, publication débloquée" do
    p = property_avec_doc
    p.update_columns(
      address_detected:  "12 rue du Haut-Rivage",
      city_detected:     "Malzéville",
      zipcode_detected:  "54220",
      address_source:    "dpe"
    )

    # HTTParty.get lève — mimique un vrai timeout ou une erreur réseau
    HTTParty.stub :get, ->(*_args) { raise Net::OpenTimeout, "read timeout" } do
      post confirm_address_property_path(p), params: {
        property: { address: "12 rue du Haut-Rivage", city: "Malzéville", zipcode: "54220" }
      }
    end
    assert_redirected_to property_path(p),
      "L'échec BAN ne doit PAS bloquer l'utilisateur — la confirmation locale reste opérante"

    p.reload
    assert_equal "12 rue du Haut-Rivage", p.address
    assert p.address_confirmed_at.present?,
      "address_confirmed_at doit être posé même si BAN a échoué (dégradation gracieuse)"
    assert_nil p.lat,        "BAN n'a pas répondu → lat reste NULL"
    assert_nil p.code_insee, "BAN n'a pas répondu → code_insee reste NULL"

    # ── Verrou métier : publication débloquée malgré code_insee absent ──
    # C2 exige address_confirmed_at, pas code_insee. Un utilisateur ne
    # doit pas être coincé si BAN est HS le jour de sa confirmation.
    p.assign_attributes(surface: 118, dpe_class: "F", status: :published)
    assert p.valid?,
      "Publication doit rester possible sans code_insee, reçu : #{p.errors.full_messages.inspect}"
  end

  test "BAN retourne features=[] : aucune écriture spéculative (lat/code_insee NULL)" do
    p = property_avec_doc

    HTTParty.stub :get, ->(*_args) { ban_response_vide } do
      post confirm_address_property_path(p), params: {
        property: { address: "adresse-inconnue-de-BAN", city: "Nulle Part", zipcode: "99999" }
      }
    end
    p.reload

    assert_equal "adresse-inconnue-de-BAN", p.address, "L'adresse saisie doit rester persistée"
    assert p.address_confirmed_at.present?, "Confirmation posée malgré BAN vide"
    assert_nil p.lat
    assert_nil p.code_insee
  end

  # ─────────────────────────────────────────────────────────────────
  # 3. BAN score faible — code_insee non persisté
  # ─────────────────────────────────────────────────────────────────

  test "BAN score < 0.4 (match incertain) : lat/lng écrits, code_insee délibérément NON persisté" do
    # Semantic voulue de GeocodingService.MIN_INSEE_SCORE : un match
    # faible pourrait rattacher au mauvais code INSEE et faire perdre
    # (ou gagner à tort) des aides locales. On préfère code_insee NULL.
    p = property_avec_doc

    HTTParty.stub :get, ->(*_args) { ban_response_ok(score: 0.30) } do
      post confirm_address_property_path(p), params: {
        property: { address: "adresse ambiguë", city: "Nancy", zipcode: "54000" }
      }
    end
    p.reload

    assert_equal 48.72, p.lat,        "lat écrit même sur score faible (utile pour la carte)"
    assert_equal 6.19,  p.lng
    assert_nil p.code_insee,
      "code_insee délibérément NULL si score BAN faible — anti-rattachement à la mauvaise commune"
    assert p.address_confirmed_at.present?, "Confirmation reste posée"
  end

  private

  def set_signed_cookie(name, value)
    request = ActionDispatch::TestRequest.create
    jar     = ActionDispatch::Cookies::CookieJar.build(request, cookies.to_hash)
    jar.signed[name] = value
    cookies[name.to_s] = jar[name.to_s]
  end
end
