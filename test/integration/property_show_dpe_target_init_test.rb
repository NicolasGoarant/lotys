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

    # Décision γ du diagnostic 3b-2 : sans matrice, le slider n'est PAS rendu
    # (jauge désactivée proprement) et un message d'invite est affiché.
    # Aucun fallback forfaitaire.
    assert_nil css_select("input#dpe-slider").first,
      "Sans matrice, input#dpe-slider ne doit PAS être rendu (jauge désactivée)"
    assert_match(/Complétez votre dossier/, response.body,
      "Le message d'invite doit s'afficher quand la matrice ne peut pas être calculée")
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

  # ── 3. Régression curseur≠cases — la matrice prime sur dpe_target ET dpe_cib ─
  # Cas qui buggait : sur un bien avec une cible DB héritée (dpe_target="C") et
  # une analyse Claude qui propose aussi "C" comme cible, mais 5 gestes cochés
  # dont la matrice prédit la classe A, le curseur initial s'affichait en C —
  # contradiction visuelle avec les cases cochées qui mènent à A.
  # Comportement attendu après correction (option 1) : le curseur suit la
  # matrice (= classe A), pas la cible héritée. Ce test resterait vert même si
  # un futur changement remettait dpe_target ou dpe_cib en première position.
  test "dpe_target='C' DB + analysis.dpe_cible='C' + 5 gestes → matrice (A) gagne" do
    p = creer_property_pour_init(
      address:                  "14 rue des Tilleuls",
      city:                     "Vandœuvre-lès-Nancy",
      zipcode:                  "54500",
      surface:                  95,
      construction_year:        1962,
      energie_chauffage:        "gaz",
      energie_chauffage_source: "extrait_description",
      dpe_class:                "F",
      dpe_target:               "C",
      travaux_selection: {
        "isolation_toiture" => true, "isolation_murs" => true,
        "chauffage" => true, "menuiseries" => true, "vmc" => true
      }
    )
    # Analyse Claude complète : travaux nécessaires pour que travaux_groupes
    # soit non vide (sinon le form du parcours est masqué et hidden field absent).
    Analysis.create!(property: p, content: {
      "energie" => {
        "dpe_estime" => "F",
        "dpe_cible"  => "C",
        "travaux"    => [
          { "poste" => "Isolation des combles",  "priorite" => 1, "cout_min" => 4_000,  "cout_max" => 8_000 },
          { "poste" => "Isolation des murs ITE", "priorite" => 2, "cout_min" => 12_000, "cout_max" => 18_000 },
          { "poste" => "Pompe à chaleur",        "priorite" => 3, "cout_min" => 10_000, "cout_max" => 15_000 },
          { "poste" => "Remplacement fenêtres",  "priorite" => 4, "cout_min" => 8_000,  "cout_max" => 12_000 },
          { "poste" => "VMC double flux",        "priorite" => 5, "cout_min" => 3_000,  "cout_max" => 5_000  }
        ]
      },
      "valeur"  => {}, "idees" => { "scenarios" => [] }
    }.to_json)

    matrix          = PropertyDpeMatrixService.call(p)
    cle             = p.travaux_actifs.sort.join(",")
    classe_attendue = matrix[:combinaisons][cle][:classe]
    idx_attendu     = DPE_ORDRE.index(classe_attendue)
    assert_equal "A", classe_attendue,
      "Pré-requis du test : la matrice doit prédire A pour cette combinaison sur Tilleuls"

    get property_path(p)
    assert_response :success

    slider = css_select("input#dpe-slider").first
    assert slider, "Le slider doit exister (matrice présente)"
    refute_equal "2", slider["value"],
      "Le slider NE DOIT PAS rester sur C (idx 2) hérité de dpe_target/dpe_cible"
    assert_equal idx_attendu.to_s, slider["value"],
      "Le slider doit être sur idx=#{idx_attendu} (classe matrice=#{classe_attendue}), " \
      "ignorant dpe_target='C' et analysis.dpe_cible='C'."

    # Le hidden field qui pilote le submit doit lui aussi refléter la classe
    # matrice (option 1 : un submit no-interaction persiste une cible cohérente
    # avec ce que l'utilisateur voit, pas la valeur DB héritée).
    hidden = css_select("input#form-dpe-target").first
    assert hidden, "Le hidden field form-dpe-target doit exister"
    assert_equal classe_attendue, hidden["value"],
      "Le hidden field doit porter la classe matrice (#{classe_attendue}), pas 'C' hérité"
  end

  # ── 2bis. Même cas dégradé mais avec gestes cochés — preuve qu'aucun
  # gain_dpe forfaitaire ne peut être réintroduit : le slider lui-même
  # n'est pas rendu sans matrice (décision γ).
  test "Property sans année + gestes cochés : slider non rendu (aucun fallback gain_dpe possible)" do
    p = creer_property_pour_init(
      construction_year: nil,
      dpe_class:         "F",
      dpe_target:        nil,
      travaux_selection: { "isolation_murs" => true, "isolation_toiture" => true, "chauffage" => true }
    )

    get property_path(p)
    assert_response :success

    assert_nil css_select("input#dpe-slider").first,
      "Même avec 3 gestes cochés, slider non rendu si matrice absente — preuve qu'aucun gain_dpe forfaitaire n'a été réintroduit"
    assert_match(/Complétez votre dossier/, response.body)
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
