require "test_helper"

# Tests du moteur DPE 3CL-inspiré (voie absolue §5bis du doc).
# Spec complète : docs/MODELE_DPE_3CL.md
#
# Stratégie : oracle §7 (F→D, source quali-ti-plaque guide MPR murs 2026)
# + un cas électrique de cohérence (pour ne pas surajuster sur un seul oracle)
# + deux garde-fous §5bis (hiérarchie des pertes, formule express Organilog ±25 %).
#
# Les paramètres du moteur sont figés dans le §5ter du doc et dans les
# constantes du service. Ces tests sont des contrôles *indépendants* — ils
# doivent tomber juste sans paramètre passé en argument.
#
# Discipline §9 : on accepte une instabilité ±5 % aux seuils.

class DpeEngineServiceTest < ActiveSupport::TestCase
  # ── Entrées du cas oracle §7 ────────────────────────────────────────────
  ORACLE_BASE = {
    surface_habitable: 120,
    annee_construction: 1962,
    energie_chauffage: :fioul,        # choisi pour tomber en F
    zone_climatique: :h1,             # Nancy
    niveaux: 2,
    surface_murs: 80,                 # §7 — fourni
    nombre_fenetres: 8,               # §7 — fourni (8 × 1,5 = 12 m²)
    toiture_rampants: false,          # « combles » §7 → perdus plats
    inclure_ecs: true                 # forfait §5ter.d
  }.freeze
  ETAT_NON_ISOLE = {
    isolation_murs:         :non_isole,
    isolation_toiture:      :non_isole,
    isolation_plancher_bas: :non_isole,
    isolation_menuiseries:  :non_isole
  }.freeze
  ETAT_TRAVAUX_ORACLE = {
    isolation_murs:         :isole,
    isolation_toiture:      :isole,
    isolation_plancher_bas: :non_isole,  # §7 ne le mentionne pas
    isolation_menuiseries:  :isole
  }.freeze

  # ────────────────────────────────────────────────────────────────────────
  # ORACLE §7 — validation principale du calage (F → D)
  # ────────────────────────────────────────────────────────────────────────

  test "oracle §7 avant travaux — passoire fioul 1962 sort en classe F" do
    r = DpeEngineService.call(**ORACLE_BASE.merge(ETAT_NON_ISOLE))
    assert_equal "F", r[:classe_finale],
      "Avant travaux : attendu F, obtenu #{r[:classe_finale]} " \
      "(EP=#{r[:conso_ep_m2]} kWhEP/m²/an cl=#{r[:classe_energie]}, " \
      "CO₂=#{r[:conso_carbone_m2]} kg/m²/an cl=#{r[:classe_carbone]})"
  end

  test "oracle §7 après travaux — murs+toit+menuiseries isolés sort en classe D" do
    r = DpeEngineService.call(**ORACLE_BASE.merge(ETAT_TRAVAUX_ORACLE))
    assert_equal "D", r[:classe_finale],
      "Après travaux : attendu D, obtenu #{r[:classe_finale]} " \
      "(EP=#{r[:conso_ep_m2]} kWhEP/m²/an cl=#{r[:classe_energie]}, " \
      "CO₂=#{r[:conso_carbone_m2]} kg/m²/an cl=#{r[:classe_carbone]})"
  end

  test "oracle §7 — gain net de 2 classes (F → D)" do
    av = DpeEngineService.call(**ORACLE_BASE.merge(ETAT_NON_ISOLE))
    ap = DpeEngineService.call(**ORACLE_BASE.merge(ETAT_TRAVAUX_ORACLE))
    idx = DpeEngineService::ORDRE_CLASSES
    gain = idx.index(av[:classe_finale]) - idx.index(ap[:classe_finale])
    assert_equal 2, gain,
      "Gain attendu = 2 classes (F→D), obtenu #{gain} " \
      "(#{av[:classe_finale]}→#{ap[:classe_finale]})"
  end

  # Marge d'instabilité §9 — le passage à D est porté par le carbone.
  test "oracle §7 — CO₂ après travaux dans fourchette stable [31 ; 35]" do
    r = DpeEngineService.call(**ORACLE_BASE.merge(ETAT_TRAVAUX_ORACLE))
    assert_includes 31.0..35.0, r[:conso_carbone_m2],
      "CO₂ après travaux hors fourchette de stabilité [31 ; 35] : " \
      "#{r[:conso_carbone_m2]} (cf §9 instabilité aux seuils)"
  end

  # ────────────────────────────────────────────────────────────────────────
  # CAS ÉLECTRIQUE — cohérence des leviers (contrôle indépendant)
  # ────────────────────────────────────────────────────────────────────────

  test "élec vs fioul à bâti identique — ratio EP/CO₂ très différent (×1,9 EP, /4 CO₂)" do
    fioul = DpeEngineService.call(**ORACLE_BASE.merge(ETAT_NON_ISOLE))
    elec  = DpeEngineService.call(
      **ORACLE_BASE.merge(ETAT_NON_ISOLE).merge(energie_chauffage: :electricite)
    )

    assert_operator elec[:conso_ep_m2], :>, fioul[:conso_ep_m2],
      "EP élec (#{elec[:conso_ep_m2]}) devrait > EP fioul (#{fioul[:conso_ep_m2]})"
    assert_operator elec[:conso_carbone_m2], :<, fioul[:conso_carbone_m2] / 2.0,
      "CO₂ élec (#{elec[:conso_carbone_m2]}) devrait être < moitié de CO₂ fioul (#{fioul[:conso_carbone_m2]})"

    ratio_elec  = elec[:conso_ep_m2]  / elec[:conso_carbone_m2]
    ratio_fioul = fioul[:conso_ep_m2] / fioul[:conso_carbone_m2]
    assert_operator ratio_elec, :>, 5 * ratio_fioul,
      "Ratio EP/CO₂ élec (#{ratio_elec.round(1)}) doit dépasser 5× celui du fioul " \
      "(#{ratio_fioul.round(1)}) — cohérence des facteurs §5a/§5b"
  end

  test "passoire élec — EP > 330 (×1,9), CO₂ < 30, classe finale F ou G" do
    r = DpeEngineService.call(
      **ORACLE_BASE.merge(ETAT_NON_ISOLE).merge(energie_chauffage: :electricite)
    )
    assert_operator r[:conso_ep_m2], :>, 330,
      "EP passoire élec doit > 330 kWhEP/m²/an (seuil F bas), obtenu #{r[:conso_ep_m2]}"
    assert_operator r[:conso_carbone_m2], :<, 30,
      "CO₂ passoire élec doit < 30 kgCO₂/m²/an (élec décarbonée), obtenu #{r[:conso_carbone_m2]}"
    assert_includes %w[F G], r[:classe_finale],
      "Passoire élec : attendu F ou G, obtenu #{r[:classe_finale]}"
  end

  # ────────────────────────────────────────────────────────────────────────
  # GARDE-FOUS §5bis — audit physique indépendant
  # ────────────────────────────────────────────────────────────────────────

  test "garde-fou Organilog — conso chauffage avant travaux dans ±25 % de l'estimation express" do
    r = DpeEngineService.call(**ORACLE_BASE.merge(ETAT_NON_ISOLE))
    e_moteur  = r[:_details][:conso_chauffage_final_kwh]
    # E = G × V × DJU × 24 / 1000 ; G passoire 2,4 (milieu §5bis) ; V=300 ; DJU H1=2500
    e_express = 2.4 * 300 * 2500 * 24 / 1000.0
    ecart_pct = ((e_moteur - e_express) / e_express * 100).abs
    assert_operator ecart_pct, :<=, 25,
      "Garde-fou Organilog : moteur=#{e_moteur} kWh vs express=#{e_express.round} kWh " \
      "— écart #{ecart_pct.round(1)} % > ±25 % (formule §5bis)"
  end

  test "garde-fou hiérarchie des pertes (§5bis) — poids des postes dans les bons ordres de grandeur" do
    r = DpeEngineService.call(**ORACLE_BASE.merge(ETAT_NON_ISOLE))
    h = r[:_details][:hierarchie_pct]
    # Cibles §5bis assouplies de ±5 points : on attrape un bug structurel
    # (toiture à 5 %, fenêtres à 40 %), pas une fourchette rigide. Le cas
    # oracle a S_mur=80 fourni (au lieu de 134,9 par défaut), donc les
    # postes murs/toit pèsent un peu plus que dans la fourchette nominale.
    assert_includes 20..35, h[:toit],         "toiture #{h[:toit]} % hors [20-35]"
    assert_includes 20..35, h[:murs],         "murs #{h[:murs]} % hors [20-35]"
    assert_includes 10..30, h[:renouv_air],   "renouv. air #{h[:renouv_air]} % hors [10-30]"
    assert_includes  5..20, h[:fenetres],     "fenêtres #{h[:fenetres]} % hors [5-20]"
    assert_includes  2..15, h[:plancher_bas], "plancher bas #{h[:plancher_bas]} % hors [2-15]"
    assert_includes  3..15, h[:pt],           "ponts thermiques #{h[:pt]} % hors [3-15]"
  end

  # ────────────────────────────────────────────────────────────────────────
  # TRACE — détail GV avant/après pour audit (utile dans le commit / PR)
  # ────────────────────────────────────────────────────────────────────────

  test "trace détaillée du calcul oracle §7 — GV avant / après pour audit" do
    av = DpeEngineService.call(**ORACLE_BASE.merge(ETAT_NON_ISOLE))
    ap = DpeEngineService.call(**ORACLE_BASE.merge(ETAT_TRAVAUX_ORACLE))

    puts
    puts "  [TRACE]  surfaces utilisées : #{av[:_details][:surfaces].inspect}"
    puts "  [AVANT]  GV=#{av[:_details][:gv]} W/K  " \
         "breakdown=#{av[:_details][:gv_breakdown].inspect}"
    puts "  [AVANT]  hiérarchie=#{av[:_details][:hierarchie_pct].inspect}"
    puts "  [AVANT]  Bch=#{av[:_details][:bch_kwh]} kWh utile  " \
         "chauffage=#{av[:_details][:conso_chauffage_final_kwh]} kWh  " \
         "ECS=#{av[:_details][:conso_ecs_final_kwh]} kWh"
    puts "  [AVANT]  → EP=#{av[:conso_ep_m2]} kWhEP/m²/an  " \
         "CO₂=#{av[:conso_carbone_m2]} kg/m²/an  classe=#{av[:classe_finale]}"
    puts "  [APRÈS]  GV=#{ap[:_details][:gv]} W/K  " \
         "breakdown=#{ap[:_details][:gv_breakdown].inspect}"
    puts "  [APRÈS]  → EP=#{ap[:conso_ep_m2]} kWhEP/m²/an  " \
         "CO₂=#{ap[:conso_carbone_m2]} kg/m²/an  classe=#{ap[:classe_finale]}"
    pct_gv    = ((1 - ap[:_details][:gv].to_f / av[:_details][:gv]) * 100).round(1)
    pct_conso = ((1 - ap[:_details][:conso_finale_totale_kwh].to_f /
                       av[:_details][:conso_finale_totale_kwh]) * 100).round(1)
    puts "  [DELTA]  GV réduit de #{pct_gv} %  |  conso finale réduite de #{pct_conso} %"

    # Garde-fou minimal : le moteur doit toujours réduire GV/conso quand on isole.
    assert ap[:_details][:gv] < av[:_details][:gv],
      "Le GV après travaux doit être inférieur au GV avant"
    assert ap[:_details][:conso_finale_totale_kwh] < av[:_details][:conso_finale_totale_kwh],
      "La conso après doit être inférieure à la conso avant"
  end

  # ────────────────────────────────────────────────────────────────────────
  # TEMPS 3a quater — le moteur apprend l'état :partiel (§3bis figé)
  # ────────────────────────────────────────────────────────────────────────

  ETAT_TOUT_PARTIEL = {
    isolation_murs:         :partiel,
    isolation_toiture:      :partiel,
    isolation_plancher_bas: :partiel,
    isolation_menuiseries:  :partiel
  }.freeze
  ETAT_TOUT_ISOLE = {
    isolation_murs:         :isole,
    isolation_toiture:      :isole,
    isolation_plancher_bas: :isole,
    isolation_menuiseries:  :isole
  }.freeze

  # ── Non-régression CRITIQUE : oracle §7 avec chiffres exacts ─────────────
  # Ces chiffres sont les ancres du Temps 1. Toute dérive = régression du moteur.
  test "ANCRAGE oracle §7 — chiffres exacts inchangés après ajout de :partiel" do
    av = DpeEngineService.call(**ORACLE_BASE.merge(ETAT_NON_ISOLE))
    ap = DpeEngineService.call(**ORACLE_BASE.merge(ETAT_TRAVAUX_ORACLE))
    # Avant — passoire fioul 1962
    assert_equal 302.8, av[:conso_ep_m2],      "EP avant : ancre Temps 1"
    assert_equal 90.8,  av[:conso_carbone_m2], "CO₂ avant : ancre Temps 1"
    assert_equal "F",   av[:classe_finale]
    # Après — murs + toiture + menuiseries isolés
    assert_equal 107.0, ap[:conso_ep_m2],      "EP après : ancre Temps 1"
    assert_equal 32.1,  ap[:conso_carbone_m2], "CO₂ après : ancre Temps 1"
    assert_equal "D",   ap[:classe_finale]
  end

  # ── Monotonie stricte : isolé < partiel < non isolé ─────────────────────
  test ":partiel — monotonie sur EP : isolé < partiel < non isolé" do
    r_non = DpeEngineService.call(**ORACLE_BASE.merge(ETAT_NON_ISOLE))
    r_par = DpeEngineService.call(**ORACLE_BASE.merge(ETAT_TOUT_PARTIEL))
    r_iso = DpeEngineService.call(**ORACLE_BASE.merge(ETAT_TOUT_ISOLE))

    assert_operator r_iso[:conso_ep_m2], :<, r_par[:conso_ep_m2],
      "EP isolé (#{r_iso[:conso_ep_m2]}) doit être < EP partiel (#{r_par[:conso_ep_m2]})"
    assert_operator r_par[:conso_ep_m2], :<, r_non[:conso_ep_m2],
      "EP partiel (#{r_par[:conso_ep_m2]}) doit être < EP non isolé (#{r_non[:conso_ep_m2]})"
  end

  test ":partiel — monotonie sur CO₂ : isolé < partiel < non isolé" do
    r_non = DpeEngineService.call(**ORACLE_BASE.merge(ETAT_NON_ISOLE))
    r_par = DpeEngineService.call(**ORACLE_BASE.merge(ETAT_TOUT_PARTIEL))
    r_iso = DpeEngineService.call(**ORACLE_BASE.merge(ETAT_TOUT_ISOLE))

    assert_operator r_iso[:conso_carbone_m2], :<, r_par[:conso_carbone_m2]
    assert_operator r_par[:conso_carbone_m2], :<, r_non[:conso_carbone_m2]
  end

  test ":partiel — monotonie sur GV : isolé < partiel < non isolé" do
    r_non = DpeEngineService.call(**ORACLE_BASE.merge(ETAT_NON_ISOLE))
    r_par = DpeEngineService.call(**ORACLE_BASE.merge(ETAT_TOUT_PARTIEL))
    r_iso = DpeEngineService.call(**ORACLE_BASE.merge(ETAT_TOUT_ISOLE))

    assert_operator r_iso[:_details][:gv], :<, r_par[:_details][:gv]
    assert_operator r_par[:_details][:gv], :<, r_non[:_details][:gv]
  end

  # ── Valeur figée du Umur partiel ────────────────────────────────────────
  # On lit DPmurs depuis le breakdown et on divise par S_mur pour récupérer
  # le U appliqué. Avec ORACLE_BASE on a surface_murs=80 et b_extérieur=1,
  # donc U_appliqué = DPmurs / 80.
  test ":partiel — U appliqué aux murs = 1,5 W/m².K (§3bis, ancré ID 71)" do
    r = DpeEngineService.call(
      **ORACLE_BASE,
      isolation_murs:         :partiel,
      isolation_toiture:      :non_isole,
      isolation_plancher_bas: :non_isole,
      isolation_menuiseries:  :non_isole
    )
    dp_murs = r[:_details][:gv_breakdown][:murs]
    u_applique = dp_murs / 80.0
    assert_in_delta 1.5, u_applique, 0.01,
      "§3bis figé : Umur_partiel doit être 1,5 W/m².K (5 cm laine intérieure + parpaing → R total ≈ 0,67), obtenu #{u_applique}"
  end

  # ── Pas de régression sur les autres tests existants ────────────────────
  test ":partiel — Umur partiel < UMUR_PLAFOND_CALCUL = 2,0 (donc pas de plafonnement applicable)" do
    # Le plafond §3 Min(Umur ; 2) ne doit pas masquer un Umur_partiel mal calé.
    # 1,5 < 2,0, donc on doit observer exactement 1,5 (testé ci-dessus). Si
    # quelqu'un montait Umur_partiel à 2,5 par erreur, le plafond lisserait
    # à 2,0 et le test précédent échouerait — c'est volontaire.
    assert_operator 1.5, :<, DpeEngineService::UMUR_PLAFOND_CALCUL
  end

  # ═════════════════════════════════════════════════════════════════════════
  # Mitoyenneté verticale — coefficients b sur toiture et plancher bas
  # ═════════════════════════════════════════════════════════════════════════
  # Pour un appartement, une paroi adjacente à un autre lot chauffé ne
  # perd rien (b=0). NF EN ISO 13789 §5.3. Sans cette correction, la
  # matrice DPE compte des déperditions fictives (démontré diag 07/07
  # sur le bien 232 : toit fictif = 33 % du GV initial d'un lot 3e étage).
  #
  # Contrat clé : quand property_type et position_lot sont nil (comportement
  # de tous les callers pré-commit-3), les résultats sont STRICTEMENT
  # identiques à avant.

  # Bien de test : mêmes paramètres physiques que le bien 232 (5 rue des
  # Ombelles), utilisé pour chiffrer l'écart avec/sans mitoyenneté.
  APPART_232_BASE = {
    surface_habitable:      72,
    annee_construction:     1965,
    energie_chauffage:      :gaz,
    zone_climatique:        :h1,
    niveaux:                1,
    isolation_murs:         :non_isole,
    isolation_toiture:      :non_isole,
    isolation_plancher_bas: :non_isole,
    isolation_menuiseries:  :non_isole,
    ventilation:            :aucune_vmc,
    inclure_ecs:            true
  }.freeze

  # ── 1. Non-régression : sans property_type ni position_lot → comportement historique ──
  test "backward-compat : property_type=nil, position_lot=nil → résultats inchangés" do
    r_avant = DpeEngineService.call(**APPART_232_BASE) # sans les nouveaux params
    r_apres = DpeEngineService.call(**APPART_232_BASE, property_type: nil, position_lot: nil)
    # Comparaison au kWh près (§9 tolérance ±5 %, ici on veut STRICT).
    assert_equal r_avant[:conso_ep_m2],     r_apres[:conso_ep_m2],
      "params nil ne doivent RIEN changer sur le Cep"
    assert_equal r_avant[:classe_finale],   r_apres[:classe_finale]
    assert_equal r_avant[:_details][:gv],   r_apres[:_details][:gv]
  end

  # ── 2. Maison : les nouveaux paramètres n'ont pas d'effet ──────────────
  test "maison + position_lot ignoré : résultats identiques à property_type=nil" do
    r_ref = DpeEngineService.call(**APPART_232_BASE) # property_type nil
    # property_type=:maison, position_lot doit être ignoré (le champ n'a pas
    # de sens pour une maison — toutes les parois donnent sur l'extérieur).
    r_maison = DpeEngineService.call(
      **APPART_232_BASE,
      property_type: :maison,
      position_lot:  :etage_intermediaire # aberrant sur maison → ignoré
    )
    assert_equal r_ref[:_details][:gv], r_maison[:_details][:gv],
      "Une maison ignore position_lot — le résultat doit être identique."
    assert_equal r_ref[:classe_finale], r_maison[:classe_finale]
  end

  # ── 3. Appartement position :inconnu → même comportement (conservateur) ──
  test "appartement position :inconnu → comportement conservateur (identique à nil)" do
    r_ref = DpeEngineService.call(**APPART_232_BASE)
    r_inc = DpeEngineService.call(**APPART_232_BASE, property_type: :appartement, position_lot: :inconnu)
    assert_equal r_ref[:_details][:gv], r_inc[:_details][:gv],
      "position_lot :inconnu doit tomber sur le comportement historique — pas de mitoyenneté inventée."
  end

  # ── 4. Appartement étage intermédiaire → toiture ET plancher b=0 ──────
  test "appartement étage intermédiaire : dp_toit=0 ET dp_plancher_bas=0" do
    r = DpeEngineService.call(
      **APPART_232_BASE,
      property_type: :appartement,
      position_lot:  :etage_intermediaire
    )
    breakdown = r[:_details][:gv_breakdown]
    assert_equal 0.0, breakdown[:toit],
      "Étage intermédiaire : la toiture est adjacente à un lot chauffé → dp_toit=0."
    assert_equal 0.0, breakdown[:plancher_bas],
      "Étage intermédiaire : le plancher est adjacent à un lot chauffé → dp_pb=0."
  end

  # ── 5. Appartement dernier étage → toiture réelle, plancher b=0 ────────
  test "appartement dernier étage : dp_toit>0 (toiture réelle), dp_plancher_bas=0" do
    r = DpeEngineService.call(
      **APPART_232_BASE,
      property_type: :appartement,
      position_lot:  :dernier_etage
    )
    breakdown = r[:_details][:gv_breakdown]
    assert_operator breakdown[:toit], :>, 0,
      "Dernier étage : toiture réelle → dp_toit > 0."
    assert_equal 0.0, breakdown[:plancher_bas],
      "Dernier étage : plancher adjacent au lot du dessous → dp_pb=0."
  end

  # ── 6. Appartement RDC → plancher réel, toiture b=0 ────────────────────
  test "appartement RDC : dp_toit=0, dp_plancher_bas>0 (dalle sur vide sanitaire)" do
    r = DpeEngineService.call(
      **APPART_232_BASE,
      property_type: :appartement,
      position_lot:  :rdc
    )
    breakdown = r[:_details][:gv_breakdown]
    assert_equal 0.0, breakdown[:toit],
      "RDC : la toiture est adjacente à un lot chauffé → dp_toit=0."
    assert_operator breakdown[:plancher_bas], :>, 0,
      "RDC : dalle sur vide sanitaire / cave → dp_pb > 0 avec b=B_PLANCHER_BAS."
  end

  # ── 7. Chiffrage impact bien 232 : 3 gestes réalistes en mitoyen gagnent 1 classe ──
  # Reproduit le calcul du diag 07/07 (avec ECS inclus comme en prod —
  # PropertyDpeService force inclure_ecs: true). Sans mitoyenneté, murs +
  # VMC + fenêtres plafonnent à D. Avec mitoyenneté verticale (étage
  # intermédiaire), les mêmes 3 gestes atteignent C — gagné 1 classe.
  # La borne C vient du CO2 : le mix gaz (0,234 kgCO₂/kWh) + ECS pousse
  # le carbone juste au-dessus du seuil B/C. Pour aller à B, il faut
  # ajouter le geste chauffage (comme bien 233) ou réduire l'ECS.
  test "bien 232 mitoyen étage intermédiaire : 3 gestes atteignent C (contre D sans mitoyenneté)" do
    etat_reno_3 = {
      isolation_murs:         :isole,
      isolation_toiture:      :non_isole, # non actionnable en mitoyen
      isolation_plancher_bas: :non_isole, # non actionnable en mitoyen
      isolation_menuiseries:  :isole,
      ventilation:            :vmc_double_flux
    }
    r_sans = DpeEngineService.call(**APPART_232_BASE.merge(etat_reno_3))
    r_avec = DpeEngineService.call(
      **APPART_232_BASE.merge(etat_reno_3),
      property_type: :appartement,
      position_lot:  :etage_intermediaire
    )
    assert_equal "D", r_sans[:classe_finale],
      "Rappel diag : sans mitoyenneté, les 3 gestes plafonnent à D (obtenu #{r_sans[:classe_finale]})."
    assert_equal "C", r_avec[:classe_finale],
      "Avec mitoyenneté verticale, les 3 gestes atteignent C (obtenu #{r_avec[:classe_finale]}). " \
      "La borne C vient du CO2 gaz+ECS (seuil B/C à 11 kgCO₂/m²) — pour aller à B, " \
      "il faut aussi le geste chauffage (comme bien 233 le proposait) ou le geste chauffe-eau."
  end

  # ── 8. Impact chiffré : sur l'état INITIAL, la mitoyenneté retire ~33 % de GV ──
  # Chiffre-clé du diag 07/07 : 180 W/K de toit + 25.9 W/K de plancher sur
  # un GV initial de 533 W/K = 38,7 % du bilan initial imputé à des parois
  # fictives pour un appartement mitoyen. Test de non-régression sur cette
  # correction structurelle.
  test "état initial appartement étage intermédiaire : GV réduit d'au moins 30 % vs modèle historique" do
    r_ref = DpeEngineService.call(**APPART_232_BASE) # sans mitoyenneté
    r_mit = DpeEngineService.call(
      **APPART_232_BASE,
      property_type: :appartement,
      position_lot:  :etage_intermediaire
    )
    reduction_pct = 100.0 * (r_ref[:_details][:gv] - r_mit[:_details][:gv]) / r_ref[:_details][:gv]
    assert_operator reduction_pct, :>=, 30.0,
      "Un appartement étage intermédiaire doit voir son GV initial réduit d'au moins 30 % " \
      "(mitoyenneté haut+bas). Obtenu #{reduction_pct.round(1)} %."
  end
end
