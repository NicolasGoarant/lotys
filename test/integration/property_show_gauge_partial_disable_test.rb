require "test_helper"
require_relative "../support/aid_rules_helper"

# Vérifie le rendu HONNÊTE de la jauge quand la matrice DPE ne peut pas être
# calculée (surface OU année manquante), et le rendu NORMAL quand tout est
# extrait.
#
# Trois exigences testées :
#   1. Source de vérité unique — jauge et en-tête lisent @property.surface
#      et @property.construction_year.
#   2. Message d'invite dynamique — ne mentionne QUE les champs réellement
#      absents (bug : le message historique citait "surface et année" même
#      quand seule l'année manquait).
#   3. Griser UNIQUEMENT la projection — la classe DPE actuelle vient du
#      document uploadé, c'est un fait fiable ; le curseur "actuel" doit
#      rester rendu en couleur sur son segment, seule la partie projection
#      (pin cible, slider, label objectif) est désactivée.
class PropertyShowGaugePartialDisableTest < ActionDispatch::IntegrationTest
  include AidRulesHelper

  CLAIM_COOKIE = ClaimToken::CLAIM_COOKIE
  TOKEN        = "JETON_GAUGE_PARTIAL_TEST"

  setup do
    seed_aid_rules!
    set_signed_cookie(CLAIM_COOKIE, TOKEN)
  end

  # ── 1. Verrou de régression — surface + année → jauge active ──────────
  # Reproduit le scénario Malzéville : les deux champs sont extraits, la
  # jauge doit être calculable, aucun bandeau d'invite ne doit apparaître.
  test "surface + construction_year extraits → jauge active, pas de bandeau" do
    p = creer_bien(surface: 118, construction_year: 1928, dpe_class: "F")

    get property_path(p)
    assert_response :success

    assert_select "script#dpe-matrix-data", { count: 1 },
      "Avec surface ET année, la matrice DPE doit être injectée"
    refute_match(/Complétez votre dossier/, response.body,
      "Aucun bandeau d'invite quand les deux champs requis sont présents")
  end

  # ── 2a. Message dynamique — seule l'année manque ──────────────────────
  # Bug observé sur le bien Malzéville : la surface (118 m²) est extraite,
  # mais l'année (1928) reste nil car le pipeline LLM l'a manquée. Le
  # message historique cite "surface et année" — le fix doit citer
  # seulement l'année.
  test "surface OK + année nil → bandeau cite l'année SEULEMENT" do
    p = creer_bien(surface: 118, construction_year: nil, dpe_class: "F")

    get property_path(p)
    assert_response :success

    assert_match(/Complétez votre dossier/, response.body)
    assert_match(/année de construction/, response.body,
      "L'année manquante doit être citée")
    refute_match(/surface habitable/, response.body,
      "La surface étant présente, elle ne doit PAS être citée comme manquante")
  end

  # ── 2b. Message dynamique — seule la surface manque ───────────────────
  test "année OK + surface nil → bandeau cite la surface SEULEMENT" do
    p = creer_bien(surface: nil, construction_year: 1928, dpe_class: "F")

    get property_path(p)
    assert_response :success

    assert_match(/Complétez votre dossier/, response.body)
    assert_match(/surface habitable/, response.body,
      "La surface manquante doit être citée")
    refute_match(/année de construction/, response.body,
      "L'année étant présente, elle ne doit PAS être citée comme manquante")
  end

  # ── 2c. Message dynamique — les deux manquent ─────────────────────────
  test "surface nil + année nil → bandeau cite les deux" do
    p = creer_bien(surface: nil, construction_year: nil, dpe_class: "F")

    get property_path(p)
    assert_response :success

    assert_match(/surface habitable/, response.body)
    assert_match(/année de construction/, response.body)
  end

  # ── 3a. La classe actuelle reste visible sans pin rond dédié ─────────
  # Depuis le fix "pin redondant" : plus de #pin-cur. La classe DPE
  # actuelle s'affiche via DEUX signaux complémentaires :
  #   1. marqueur textuel « ▼ actuel » au-dessus du bon segment,
  #   2. segment coloré à opacité pleine (les autres à 0.4).
  # Ces deux signaux sont inconditionnels (rendus même quand la matrice
  # est absente). Le pin rond est réservé à l'objectif.
  test "année manquante → marqueur ▼ actuel + segment F opaque restent visibles" do
    p = creer_bien(surface: 118, construction_year: nil, dpe_class: "F")

    get property_path(p)
    assert_response :success

    assert_match(/▼ actuel/, response.body,
      "Le marqueur textuel « ▼ actuel » doit être présent même sans matrice")
    # Le segment "F" reste rendu et à opacité pleine (opacity:1 dans style
    # inline) — les autres segments sont à opacity:0.4.
    assert_match(/opacity:1;.>F</, response.body,
      "Le segment DPE actuel (F) doit rester à opacité pleine")
    # Verrou anti-régression du bug rendu : plus de pin rond doublon.
    assert_nil css_select("#pin-cur").first,
      "Plus de #pin-cur rond — remplacé par le marqueur textuel (fix doublon)"
  end

  # ── 3b. Griser uniquement la projection — pin cible ABSENT quand matrice nil ─
  # La projection (classe atteignable) est justement ce qui n'est pas
  # calculable. Le pin cible (#pin-tgt) et le slider ne doivent PAS être
  # rendus dans ce cas — plutôt qu'affichés greyés-mais-présents.
  test "matrice absente → pin cible (#pin-tgt) et slider NON rendus" do
    p = creer_bien(surface: 118, construction_year: nil, dpe_class: "F")

    get property_path(p)
    assert_response :success

    assert_nil css_select("#pin-tgt").first,
      "Le pin cible ne doit PAS être rendu quand la matrice ne peut pas projeter"
    assert_nil css_select("input#dpe-slider").first,
      "Le slider ne doit PAS être rendu quand la matrice est absente"
  end

  # ── 3c. Matrice présente — seul pin-tgt existe, pas de doublon ────────
  # Le pin rond est RÉSERVÉ à l'objectif. La classe actuelle reste
  # matérialisée par le marqueur textuel « ▼ actuel » + segment opaque.
  # Anti-régression : rétablir #pin-cur créerait à nouveau le doublon
  # visuel signalé en prod.
  test "matrice présente → uniquement pin-tgt (pas de #pin-cur, marqueur textuel suffit)" do
    p = creer_bien(surface: 118, construction_year: 1928, dpe_class: "F")

    get property_path(p)
    assert_response :success

    assert css_select("#pin-tgt").first,       "Pin cible présent"
    assert css_select("input#dpe-slider").first, "Slider présent"
    assert_nil css_select("#pin-cur").first,
      "Aucun pin rond doublon pour la classe actuelle — marqueur textuel suffit"
    assert_match(/▼ actuel/, response.body,
      "Le marqueur textuel « ▼ actuel » reste présent aussi avec matrice")
  end

  private

  def set_signed_cookie(name, value)
    request = ActionDispatch::TestRequest.create
    jar     = ActionDispatch::Cookies::CookieJar.build(request, cookies.to_hash)
    jar.signed[name] = value
    cookies[name.to_s] = jar[name.to_s]
  end

  def creer_bien(attrs)
    Property.create!({
      address:        "12 rue du Haut-Rivage",
      city:           "Malzéville",
      zipcode:        "54220",
      property_type:  "maison",
      status:         :analyzed,
      claim_token:    TOKEN,
      household_size: 3,
      rfr:            25_000,
      dpe_target:     nil
    }.merge(attrs))
  end
end
