require "test_helper"
require "minitest/mock"
require_relative "../support/aid_rules_helper"

# ═══════════════════════════════════════════════════════════════════════
#   C5 — Bandeau de confirmation d'adresse + action confirm_address
#
#   Le parcours "documents sans adresse" (C2) crée une Property avec
#   address vide et docs rattachés. Le pipeline dépose une détection LLM
#   dans address_detected (C3). Cette suite vérifie :
#     1. Le bandeau s'affiche tant que address est vide.
#     2. POST confirm_address avec les valeurs détectées telles quelles
#        conserve address_source d'extraction.
#     3. POST confirm_address avec des valeurs éditées bascule
#        address_source en "manuel".
#     4. address_confirmed_at est posé (permet la publication, cf. C2).
#     5. Trio incomplet → refusé, address reste NULL, bandeau reste
#        affiché.
#     6. Un visiteur random (sans cookie claim_token et pas propriétaire)
#        NE peut PAS confirmer l'adresse d'un bien qui n'est pas le sien.
#
#   Aucun appel réseau : HTTParty.get stubbé pour GeocodingService.
#   AidRule seedées via AidRulesHelper (LocalAidCalculator déclenché
#   dans la foulée par confirm_address, cf. C6 pour la vue).
# ═══════════════════════════════════════════════════════════════════════
class PropertyConfirmAddressTest < ActionDispatch::IntegrationTest
  include AidRulesHelper

  CLAIM_COOKIE = ClaimToken::CLAIM_COOKIE
  TOKEN        = "JETON_CONFIRM_ADDRESS_TEST"

  setup do
    seed_aid_rules!
    set_signed_cookie(CLAIM_COOKIE, TOKEN)
  end

  # Réponse BAN stub : score>0.4, coordonnées valides, citycode Malzéville.
  def ban_response_ok
    Struct.new(:body).new({
      "features" => [
        {
          "geometry"   => { "coordinates" => [6.19, 48.72] },
          "properties" => { "score" => 0.87, "citycode" => "54339" }
        }
      ]
    }.to_json)
  end

  # Property orpheline créée dans le parcours C2 (docs sans adresse),
  # avec un doc rattaché et une détection LLM (C3) déposée.
  def property_avec_detection(address_detected: "12 rue du Haut-Rivage",
                              city_detected:    "Malzéville",
                              zipcode_detected: "54220",
                              source:           "dpe")
    p = Property.new(claim_token: TOKEN)
    p.save(validate: false)
    p.documents.create!(document_type: :dpe, name: "dpe.pdf")
    p.update_columns(
      address_detected:  address_detected,
      city_detected:     city_detected,
      zipcode_detected:  zipcode_detected,
      address_source:    source
    )
    p
  end

  def property_sans_detection
    p = Property.new(claim_token: TOKEN)
    p.save(validate: false)
    p.documents.create!(document_type: :dpe, name: "dpe.pdf")
    p
  end

  # ═══════════════════════════════════════════════════════════════════
  # Tri-état du bandeau adresse : la vue ne doit PAS afficher un message
  # d'échec de détection tant que le job d'extraction tourne.
  #   ÉTAT 1 : status=analyzing (extraction en cours) → note douce, PAS
  #            de bandeau de confirmation, PAS de formulaire.
  #   ÉTAT 2 : analyse finie + address_detected présent → bandeau
  #            confirmation (test "détection DPE" ci-dessous).
  #   ÉTAT 3 : analyse finie + address_detected vide → bandeau saisie
  #            manuelle avec formulaire (test "sans détection" ci-dessous).
  # ═══════════════════════════════════════════════════════════════════

  test "ÉTAT 1 — status=analyzing + detection vide : note douce, PAS de bandeau d'échec" do
    p = property_sans_detection
    p.update_columns(status: Property.statuses[:analyzing])

    get property_path(p)
    assert_response :success

    # Note douce présente
    assert_select "#address-analyzing-note", { count: 1 },
      "Pendant l'analyse, la note douce 'recherche adresse' doit être visible"
    assert_match(/recherchons l'adresse/i, response.body)

    # Bandeau de confirmation ABSENT (pas de faux échec pendant l'extraction)
    assert_nil css_select("#confirm-address").first,
      "Le bandeau de confirmation ne doit PAS être rendu pendant l'analyse — " \
      "c'est le bug prod où le libellé 'nous n'avons pas pu déduire' apparaissait alors que le job tournait"
    refute_match(/n'avons pas pu déduire/i, response.body,
      "Le libellé d'échec ne doit PAS coexister avec le panneau 'Analyse en cours'")

    # Local-aids-locked aussi verrouillé pendant analyzing (pointe #confirm-address qui n'existe pas)
    assert_nil css_select("#local-aids-locked").first,
      "Le rappel 'aides locales à confirmer' ne doit pas pointer vers un bandeau absent"
  end

  test "ÉTAT 1 — status=analyzing + detection déjà remplie (course improbable) : analyzing prime encore" do
    # Cas limite : le job a déjà posé address_detected mais status n'est
    # pas encore basculé à :analyzed (transaction en cours). On préfère
    # laisser le polling reload plutôt que d'afficher un bandeau avant
    # que le status ne le confirme.
    p = property_avec_detection
    p.update_columns(status: Property.statuses[:analyzing])

    get property_path(p)
    assert_response :success

    assert_select "#address-analyzing-note", { count: 1 }
    assert_nil css_select("#confirm-address").first,
      "Tant qu'analyzing, la note prime — le polling rafraîchira dès le passage à :analyzed"
  end

  test "ÉTAT 3 — status=analyzed + detection vide : bandeau saisie manuelle" do
    p = property_sans_detection
    # Property.new + save(validate:false) laisse status=draft (0). Draft
    # = analyse terminée (avec ou sans succès) donc on montre le bandeau.
    # Ici on est explicite : draft ≠ analyzing.
    refute p.analyzing?, "Fixture doit être hors :analyzing"

    get property_path(p)
    assert_response :success

    assert_select "#confirm-address", { count: 1 }
    assert_match(/n'avons pas pu déduire/i, response.body)
    # Note douce absente une fois hors analyzing
    assert_nil css_select("#address-analyzing-note").first
  end

  # ── 1. Bandeau visible quand address est vide, texte source explicite ──
  test "bandeau visible avec détection DPE — texte source, valeurs pré-remplies" do
    p = property_avec_detection(source: "dpe")

    get property_path(p)
    assert_response :success

    assert_select "#confirm-address", { count: 1 },
      "Le bandeau de confirmation doit être rendu tant qu'address est vide"
    assert_match(/détecté cette adresse/i, response.body)
    assert_match(/votre DPE/i, response.body,
      "Le libellé humain d'address_source doit apparaître (helper t_address_source)")
    # Valeurs détectées pré-remplies dans les inputs
    assert_select "input[name='property[address]'][value='12 rue du Haut-Rivage']"
    assert_select "input[name='property[city]'][value='Malzéville']"
    assert_select "input[name='property[zipcode]'][value='54220']"
  end

  test "bandeau visible sans détection — message saisie manuelle" do
    p = property_sans_detection

    get property_path(p)
    assert_response :success

    assert_select "#confirm-address"
    assert_match(/n'avons pas pu déduire/i, response.body)
    # Inputs vides (aucune détection)
    assert_select "input[name='property[address]'][value='']"
  end

  # ── 2. Confirmation SANS édition → source d'extraction conservée ────
  test "POST confirm_address avec valeurs détectées telles quelles → source dpe conservée" do
    p = property_avec_detection(source: "dpe")

    HTTParty.stub :get, ->(*_args) { ban_response_ok } do
      post confirm_address_property_path(p), params: {
        property: {
          address: "12 rue du Haut-Rivage",
          city:    "Malzéville",
          zipcode: "54220"
        }
      }
    end
    assert_redirected_to property_path(p)

    p.reload
    assert_equal "12 rue du Haut-Rivage", p.address
    assert_equal "Malzéville",             p.city
    assert_equal "54220",                  p.zipcode
    assert_equal "dpe",                    p.address_source,
      "Source d'extraction conservée quand l'user valide sans éditer"
    assert p.address_confirmed_at.present?, "address_confirmed_at doit être posé"
    # Géocodage BAN a été effectué → lat/lng/code_insee posés
    assert_equal 48.72,   p.lat
    assert_equal 6.19,    p.lng
    assert_equal "54339", p.code_insee
  end

  # ── 3. Confirmation AVEC édition → source bascule en "manuel" ───────
  test "POST confirm_address avec adresse éditée → source bascule en manuel" do
    p = property_avec_detection(source: "dpe")

    HTTParty.stub :get, ->(*_args) { ban_response_ok } do
      post confirm_address_property_path(p), params: {
        property: {
          address: "14 rue du Haut-Rivage",  # ← corrigé par l'user
          city:    "Malzéville",
          zipcode: "54220"
        }
      }
    end

    p.reload
    assert_equal "14 rue du Haut-Rivage", p.address
    assert_equal "manuel",                p.address_source,
      "Édition user → la donnée ne vient plus tout à fait du DPE"
  end

  # ── 4. Confirmation débloque la publication ─────────────────────────
  test "après confirmation address_confirmed_at posé → la publication devient possible" do
    p = property_avec_detection(source: "dpe")

    HTTParty.stub :get, ->(*_args) { ban_response_ok } do
      post confirm_address_property_path(p), params: {
        property: { address: "12 rue du Haut-Rivage", city: "Malzéville", zipcode: "54220" }
      }
    end

    p.reload
    p.assign_attributes(surface: 118, dpe_class: "F", status: :published)
    assert p.valid?,
      "Publication doit passer après confirmation, reçu : #{p.errors.full_messages.inspect}"
  end

  # ── 5. Trio incomplet → refusé sans effet de bord ───────────────────
  test "POST confirm_address avec city vide → refusé, address reste NULL" do
    p = property_avec_detection

    HTTParty.stub :get, ->(*_args) { raise "BAN ne doit PAS être appelé sur erreur" } do
      post confirm_address_property_path(p), params: {
        property: { address: "12 rue du Haut-Rivage", city: "", zipcode: "54220" }
      }
    end

    p.reload
    assert_nil p.address,              "address ne doit PAS être posée sur trio incomplet"
    assert_nil p.address_confirmed_at, "confirmation ne doit PAS être posée sur trio incomplet"
    assert_equal "dpe", p.address_source, "address_source d'extraction préservé (pas d'écriture)"
  end

  # ── C6 : la confirmation déclenche bien LocalAidCalculator ──────────
  # Verrou complémentaire de la garde côté job (skip LocalAidCalculator
  # tant qu'address vide). Stub sur LocalAidCalculator.new pour compter
  # les invocations — indépendant du contenu de LocalAidScheme (la base
  # de test n'en seede aucun, mais l'intention testée est bien "l'action
  # confirm_address a re-appelé le calculator").
  test "POST confirm_address → LocalAidCalculator invoqué (recalcul C6)" do
    p = property_avec_detection

    calls = 0
    fake_calculator = Object.new
    fake_calculator.define_singleton_method(:call) { calls += 1; [] }

    LocalAidCalculator.stub :new, ->(*_args) { fake_calculator } do
      HTTParty.stub :get, ->(*_args) { ban_response_ok } do
        post confirm_address_property_path(p), params: {
          property: { address: "12 rue du Haut-Rivage", city: "Malzéville", zipcode: "54220" }
        }
      end
    end

    assert_equal 1, calls,
      "LocalAidCalculator.new(...).call doit avoir été invoqué exactement une fois par la confirmation"
  end

  # ── C6 : vue résultats — cadenas "aides locales à venir" visible ──
  test "show — address vide : bloc 'aides locales à venir' visible" do
    p = property_avec_detection
    get property_path(p)
    assert_response :success
    assert_select "#local-aids-locked", { count: 1 },
      "Le rappel 'aides locales après confirmation' doit être visible"
    assert_match(/aides locales/i, response.body)
  end

  test "show — address confirmée : bloc 'aides locales à venir' ABSENT" do
    p = property_avec_detection
    HTTParty.stub :get, ->(*_args) { ban_response_ok } do
      post confirm_address_property_path(p), params: {
        property: { address: "12 rue du Haut-Rivage", city: "Malzéville", zipcode: "54220" }
      }
    end

    get property_path(p)
    assert_response :success
    assert_select "#local-aids-locked", { count: 0 },
      "Une fois l'adresse confirmée, plus de rappel"
  end

  # ── 6. Étanchéité : un visiteur random ne peut PAS confirmer ────────
  test "visiteur SANS cookie claim_token ne peut PAS confirmer l'adresse d'un bien" do
    p = property_avec_detection
    # On efface le cookie de l'utilisateur test pour simuler un visiteur étranger.
    cookies.delete(CLAIM_COOKIE.to_s)

    HTTParty.stub :get, ->(*_args) { raise "BAN ne doit PAS être appelé" } do
      post confirm_address_property_path(p), params: {
        property: { address: "999 rue Pirate", city: "Nowhere", zipcode: "00000" }
      }
    end
    assert_redirected_to root_path

    p.reload
    assert_nil p.address, "L'adresse ne doit pas avoir été posée par un visiteur non autorisé"
  end

  private

  def set_signed_cookie(name, value)
    request = ActionDispatch::TestRequest.create
    jar     = ActionDispatch::Cookies::CookieJar.build(request, cookies.to_hash)
    jar.signed[name] = value
    cookies[name.to_s] = jar[name.to_s]
  end
end
