require "test_helper"
require_relative "../support/aid_rules_helper"

# Asservit l'init server-side de tgt_idx_estime sur la matrice DPE
# pré-calculée (PropertyDpeMatrixService) — Temps 3b-2 commit 1.
#
# Premier pas du débranchement de DPE_IMPACT : on remplace UNIQUEMENT le
# calcul serveur de tgt_idx_estime à show.html.erb:65-69. La jauge
# interactive (recalcTravaux + onSliderChange + deriveSelectionForTarget)
# continue de tourner sur DPE_IMPACT et n'est PAS touchée par ce commit.
#
# Cas couverts :
#   1. Matrice présente → tgt_idx dérive de la classe matrice (et non plus
#      de TravauxMapperService.gain_dpe).
#   2. Matrice absente (année manquante) → tgt_idx vaut cur_idx, sans
#      réintroduire de fallback forfaitaire. Décision γ du diagnostic 3b-2.
class PropertyShowDpeTargetInitTest < ActionDispatch::IntegrationTest
  include AidRulesHelper

  CLAIM_COOKIE = ClaimToken::CLAIM_COOKIE
  TOKEN        = "JETON_INIT_TEST_3B2"
  DPE_ORDRE    = %w[A B C D E F G].freeze

  setup do
    seed_aid_rules!
    set_signed_cookie(CLAIM_COOKIE, TOKEN)
  end

  # ── 1. Cas nominal — matrice présente, init = lookup matrice ──────────
  # CRUCIAL : on doit forcer dpe_target=nil dans la création ET ré-écraser
  # une éventuelle dérivation côté serveur. Sinon `tgt_idx` à L69 prend
  # `dpe_target` au lieu de `tgt_idx_estime` et le test ne mesurerait pas
  # ce qu'on veut.
  test "Property avec surface+année+énergie : tgt_idx_estime dérive de la classe matrice" do
    # On choisit délibérément un cas où forfait et matrice divergent : sur le
    # Tilleuls (gaz 1962), [isolation_murs] seul donne :
    #   - forfait gain_dpe = 1.0 → round 1 → tgt = 5-1 = 4 (E)
    #   - matrice combinaisons["isolation_murs"] = D → idx 3
    # → test rouge avec l'init forfaitaire actuel, vert une fois bascule matrice.
    p = creer_property_pour_init(
      construction_year:        1962,
      energie_chauffage:        "gaz",
      energie_chauffage_source: "extrait_description",
      dpe_class:                "F",
      dpe_target:               nil,
      travaux_selection:        { "isolation_murs" => true }
    )

    # Calcul ce que la matrice doit donner pour les gestes actifs réels
    matrix = PropertyDpeMatrixService.call(p)
    cle = p.travaux_actifs.sort.join(",")
    classe_attendue = matrix[:combinaisons][cle][:classe]
    idx_attendu = DPE_ORDRE.index(classe_attendue)

    get property_path(p)
    assert_response :success

    assert_select "script#dpe-matrix-data", { count: 1 },
      "La balise dpe-matrix-data doit être présente quand surface+année OK"

    # Le slider est positionné sur l'index dérivé de la matrice (pas du forfait).
    # Note : on lit l'attribut via Nokogiri plutôt que assert_select[value=?]
    # qui semble buggué sur ce template multi-lignes.
    slider = css_select("input#dpe-slider").first
    assert slider, "input#dpe-slider doit exister dans le HTML"
    assert_equal idx_attendu.to_s, slider["value"],
      "Le slider doit être positionné sur idx=#{idx_attendu} (classe matrice=#{classe_attendue}), " \
      "pour la combinaison [#{cle}] ; obtenu value=#{slider['value']}"
  end

  # ── 2. Cas dégradé — matrice absente, pas de fallback forfaitaire ────
  test "Property sans construction_year : matrice absente, tgt_idx_estime = cur_idx (PAS de gain_dpe)" do
    p = creer_property_pour_init(
      construction_year: nil,
      dpe_class:         "F",
      dpe_target:        nil
    )

    get property_path(p)
    assert_response :success

    assert_select "script#dpe-matrix-data", { count: 0 },
      "La balise dpe-matrix-data doit être absente quand l'année manque"

    # cur_idx = index DPE actuel (F = 5). Si gain_dpe était réintroduit en repli,
    # il vaudrait 0 pour travaux_selection vide → tgt = cur_idx aussi. Mais si
    # travaux_selection était non vide, gain_dpe le décalerait — d'où le contrôle
    # avec travaux_selection NON vide ci-dessous.
    slider = css_select("input#dpe-slider").first
    assert slider
    assert_equal DPE_ORDRE.index("F").to_s, slider["value"],
      "Sans matrice ET avec travaux_selection vide, tgt_idx_estime doit = cur_idx (F=5)"
  end

  # ── 1bis. Verrou Tilleuls anonyme — cohérence init/jauge ────────────────
  # Reproduit le bien oracle Lauze ID 107 : 95 m², 1962, gaz extrait, F.
  # SANS dpe_target — parcours d'estimation anonyme où tgt_idx_estime pilote
  # vraiment l'init. Test de régression pour s'assurer qu'à toute évolution
  # de la jauge interactive (Temps 3b-2 commits 2 et 3), le pin INITIAL reste
  # cohérent avec ce que la matrice prédit pour la combinaison cochée.
  test "Tilleuls anonyme — pin initial cohérent avec la matrice (verrou init↔jauge)" do
    p = creer_property_pour_init(
      address:                  "14 rue des Tilleuls",
      city:                     "Vandœuvre-lès-Nancy",
      zipcode:                  "54500",
      surface:                  95,
      construction_year:        1962,
      energie_chauffage:        "gaz",
      energie_chauffage_source: "extrait_description",
      dpe_class:                "F",
      dpe_target:               nil,
      travaux_selection:        {
        "isolation_murs" => true, "isolation_toiture" => true, "menuiseries" => true
      }
    )

    matrix          = PropertyDpeMatrixService.call(p)
    cle             = p.travaux_actifs.sort.join(",")
    classe_attendue = matrix[:combinaisons][cle][:classe]
    idx_attendu     = DPE_ORDRE.index(classe_attendue)

    get property_path(p)
    assert_response :success

    assert_select "script#dpe-matrix-data", { count: 1 },
      "Sur Tilleuls anonyme, la balise dpe-matrix-data doit être injectée"
    slider = css_select("input#dpe-slider").first
    assert slider, "Le slider doit exister sur Tilleuls (matrice présente)"
    assert_equal idx_attendu.to_s, slider["value"],
      "Pin initial sur Tilleuls (gestes=#{cle}) doit pointer sur idx=#{idx_attendu} " \
      "(matrice classe=#{classe_attendue}). Le commit 3b-2/2 puis 3b-2/3 ne doivent " \
      "pas dérégler cet acquis."
  end

  # ── 2bis. Même cas dégradé mais avec gestes cochés — le test qui prouve qu'on
  # ne retombe pas sur gain_dpe (sinon le slider sauterait depuis cur_idx).
  test "Property sans année + gestes cochés : tgt_idx_estime reste cur_idx (PAS de gain_dpe forfaitaire)" do
    p = creer_property_pour_init(
      construction_year: nil,
      dpe_class:         "F",
      dpe_target:        nil,
      travaux_selection: { "isolation_murs" => true, "isolation_toiture" => true, "chauffage" => true }
    )

    get property_path(p)
    assert_response :success

    # Si gain_dpe était réintroduit en repli : 1.0+1.0+1.5 = 3.5 → arrondi 4 → tgt=cur_idx-4 = 1 (B)
    # On veut : tgt = cur_idx = 5 (F), aucun saut, parce que la matrice est
    # absente et qu'il n'y a PAS de fallback forfaitaire.
    slider = css_select("input#dpe-slider").first
    assert slider
    assert_equal DPE_ORDRE.index("F").to_s, slider["value"],
      "Sans matrice, même avec 3 gestes cochés, slider doit rester à cur_idx — " \
      "preuve qu'aucun gain_dpe forfaitaire n'a été réintroduit en repli ; obtenu value=#{slider['value']}"
  end

  private

  def set_signed_cookie(name, value)
    request = ActionDispatch::TestRequest.create
    jar     = ActionDispatch::Cookies::CookieJar.build(request, cookies.to_hash)
    jar.signed[name] = value
    cookies[name.to_s] = jar[name.to_s]
  end

  def creer_property_pour_init(attrs)
    Property.create!({
      address:       "1 rue Init Test",
      city:          "Nancy",
      zipcode:       "54000",
      surface:       95,
      property_type: "maison",
      status:        :analyzed,
      claim_token:   TOKEN,
      household_size: 3,
      rfr:            25_000
    }.merge(attrs))
  end
end
