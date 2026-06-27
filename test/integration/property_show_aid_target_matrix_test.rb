require "test_helper"
require_relative "../support/aid_rules_helper"

# Verrou : le calcul des aides et le libellé « objectif X » doivent suivre
# la classe DPE atteignable par la matrice (PropertyDpeMatrixService) plutôt
# que le forfait DB @property.dpe_target. Sans ça, on a une incohérence
# visible au premier rendu : la jauge pointe sur la classe matrice (ex. B
# ou A), mais la card Aides affiche « objectif C » et calcule sur C —
# manque de montant MPR, GN Rénovation Globale piégée en « À débloquer ».
#
# Couvre :
#   - PropertiesController#show (calcul @dpe_matrix + override + @dpe_target_effectif)
#   - AidProjectionService (nouveau kwarg current_target)
#   - _simple_aids.html.erb (libellé via dpe_target_effectif)
#
# Politique : aucun fallback caché. Quand la matrice est absente, on
# retombe explicitement sur @p.dpe_target (libellé et calcul restent
# cohérents avec ce qu'AidCalculator a réellement utilisé).
class PropertyShowAidTargetMatrixTest < ActionDispatch::IntegrationTest
  include AidRulesHelper

  CLAIM_COOKIE = ClaimToken::CLAIM_COOKIE
  TOKEN        = "JETON_AID_TARGET_MATRIX"

  setup do
    seed_aid_rules!
    set_signed_cookie(CLAIM_COOKIE, TOKEN)
  end

  # ── Cas central : matrice = B (≠ forfait DB = C) ─────────────────────
  # Configuration choisie pour valider les DEUX effets de la correction
  # en un seul test :
  #   - libellé : doit passer de « objectif C » (forfait) à « objectif B »
  #     (matrice), donc preuve que dpe_target_effectif arrive au partial.
  #   - GN Réno Globale : B franchit le seuil A/B → l'aide passe de
  #     aides_potentielles (« À débloquer ») à subventions (active row).
  #   - AidProjectionService : la projection itère désormais à partir de
  #     B (matrice) et non plus de C (forfait DB).
  test "matrice=B alors que dpe_target DB='C' : libellé suit B, GN promue en aide active" do
    # 4 macros incluant `vmc` : indispensable pour qu'AidCalculator déclenche
    # eligible_parcours_accompagne? (la chaîne `ventilation` lit `vmc` dans
    # travaux_prevus, qui passe par le filtre travaux_actifs). Sans vmc dans
    # la liste, parcours_accompagné = false → pas de MPR Ampleur, pas de GN
    # Rénovation Globale, donc rien à projeter et le libellé n'est pas rendu.
    p = creer_property!(
      dpe_target: "C",
      travaux_selection: {
        "isolation_murs"        => true,
        "isolation_plancher_bas" => true,
        "chauffage"             => true,
        "vmc"                   => true
      }
    )

    # Pré-requis : la matrice doit prédire B pour cette combinaison sur
    # Tilleuls 1962 gaz. Si ce verrou casse, c'est PropertyDpeMatrixService
    # qui a évolué — pas le branchement override qu'on teste ici.
    matrix          = PropertyDpeMatrixService.call(p)
    cle             = p.travaux_actifs.sort.join(",")
    classe_attendue = matrix[:combinaisons][cle][:classe]
    assert_equal "B", classe_attendue,
                 "Pré-requis : la matrice doit prédire B pour les 3 gestes cochés"

    get property_path(p)
    assert_response :success

    # 1. Le libellé « objectif C » (forfait DB) ne doit plus apparaître.
    #    Avant correction : AidCalc calculait sur C → GN Réno Globale en
    #    « À débloquer » + AidProjectionService trouvait un delta de C vers
    #    B (où GN bascule) → le partial rendait « objectif <strong>C</strong> ».
    #    Après correction : AidCalc calcule sur B (matrice) → GN déjà active,
    #    projection de B vers A nulle (rien de plus à débloquer pour ce
    #    profil F/passoire/tres_modeste) → invitation projection absente, et
    #    surtout aucune trace du forfait C dans le corps.
    refute_match %r{objectif <strong>C</strong>}, response.body,
                 "Le libellé ne doit plus exposer le forfait DB obsolète (C). " \
                 "S'il apparaît, c'est qu'AidProjectionService itère encore " \
                 "depuis le forfait DB et non depuis la classe matrice."

    # 2. Grand Nancy Rénovation Globale : matrice=B franchit le seuil A/B,
    #    donc l'aide doit être en SUBVENTIONS (active row visible), pas en
    #    AIDES POTENTIELLES (bloc « À débloquer » masqué côté serveur).
    gn_active_row = css_select("#gn-active-row").first
    assert gn_active_row, "Le bloc #gn-active-row doit exister"
    assert_match %r{display:\s*flex}, gn_active_row["style"].to_s,
                 "GN Réno Globale doit être ACTIVE (matrice=B franchit le seuil A/B)"

    gn_potential = css_select("#gn-potential-block").first
    assert gn_potential, "Le bloc #gn-potential-block doit exister dans le markup"
    assert_match %r{display:\s*none}, gn_potential["style"].to_s,
                 "Le bloc « À débloquer » doit être masqué quand GN est active"
  end

  # ── Cas dégradé : matrice indisponible, fallback explicite sur le forfait ─
  test "matrice indisponible (année manquante) : fallback explicite sur le forfait DB" do
    # Sans construction_year, PropertyDpeMatrixService refuse → @dpe_matrix
    # reste nil dans le controller, dpe_target_override reste nil pour
    # AidCalculator → service retombe sur @p.dpe_target. C'est le chemin
    # de dégradation explicite, identique à celui de la jauge (qui se
    # désactive aussi). Aucun forfait caché à un autre étage.
    # Le travaux_selection contient les 5 macros : sans cela, le filtrage
    # AidCalc bloquerait l'éligibilité parcours_accompagné (faute de
    # ventilation/menuiseries dans la liste filtrée), GN Réno Globale ne
    # serait pas calculée du tout, et la projection AidProjectionService
    # ne pourrait pas conclure à un delta — donc pas de libellé rendu.
    # Avec les 5 macros, projection itère de C vers B/A, trouve un delta
    # via GN Réno Globale, le libellé « objectif C » est rendu et atteste
    # que le fallback dpe_target_effectif → @property.dpe_target a bien
    # traversé jusqu'au partial.
    p = creer_property!(
      dpe_target:        "C",
      construction_year: nil,
      travaux_selection: {
        "isolation_murs"   => true,
        "isolation_toiture" => true,
        "chauffage"        => true,
        "menuiseries"      => true,
        "vmc"              => true
      }
    )

    get property_path(p)
    assert_response :success

    # Libellé : on retombe sur le forfait DB (C), pas de matrice à exploiter.
    assert_match %r{objectif <strong>C</strong>}, response.body,
                 "Sans matrice, le libellé doit refléter le forfait DB (C) — fallback explicite"
  end

  private

  def set_signed_cookie(name, value)
    request = ActionDispatch::TestRequest.create
    jar     = ActionDispatch::Cookies::CookieJar.build(request, cookies.to_hash)
    jar.signed[name] = value
    cookies[name.to_s] = jar[name.to_s]
  end

  # Bien éligible MPR Ampleur + GN Réno Globale (Vandœuvre, maison ≥ 15 ans,
  # 2+ isolations + VMC + chauffage). Les SURFACES portent la qualification
  # parcours_accompagné côté AidCalculator (lecture des colonnes
  # surface_*), tandis que travaux_selection contrôle la combinaison
  # passée à PropertyDpeMatrixService — les deux sont volontairement
  # disjoints pour pouvoir piloter indépendamment l'éligibilité MPR
  # et la classe matrice atteinte.
  def creer_property!(dpe_target:, travaux_selection:, construction_year: 1962)
    p = Property.create!(
      address:                  "14 rue des Tilleuls",
      city:                     "Vandœuvre-lès-Nancy",
      zipcode:                  "54500",
      code_insee:               "54547",  # Vandœuvre — déclenche territory_grand_nancy?
      surface:                  95,
      property_type:            "maison",
      construction_year:        construction_year,
      energie_chauffage:        "gaz",
      energie_chauffage_source: "extrait_description",
      dpe_class:                "F",
      dpe_target:               dpe_target,
      status:                   :analyzed,
      claim_token:              TOKEN,
      household_size:           3,
      rfr:                      25_000,
      surface_ite:              80,
      surface_combles_perdus:   40,
      surface_plancher_bas:     40,
      vmc_double_flux:          true,
      nb_parois_vitrees:        4,
      pac_air_eau:              true,
      travaux_selection:        travaux_selection
    )

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
      "valeur"  => {},
      "idees"   => { "scenarios" => [] }
    }.to_json)

    p
  end
end
