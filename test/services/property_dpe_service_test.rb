require "test_helper"

# Tests de PropertyDpeService — pont entre l'état d'un bien et le moteur
# 3CL DpeEngineService (Temps 1). Calcule classe avant/après application
# d'un ensemble de gestes cochés.
#
# Discipline structurelle : l'état initial est OBLIGATOIRE et JAMAIS inventé
# (cf. diagnostic Temps 1.5 — Property ne stocke pas l'état de chauffage ni
# d'isolation par poste de façon fiable).
#
# Spec : docs/MODELE_DPE_3CL.md (§5bis-§5ter).

class PropertyDpeServiceTest < ActiveSupport::TestCase
  # ── Cas oracle §7 — bien Lauze de référence ─────────────────────────────
  ORACLE_BASE = {
    surface: 120,
    annee_construction: 1962,
    zone_climatique: :h1,         # Nancy
    surface_murs: 80,             # §7 — fourni
    nombre_fenetres: 8            # §7 — fourni (8 × 1,5 = 12 m²)
  }.freeze

  ORACLE_ETAT_INITIAL = {
    energie_chauffage:      :fioul,         # choisi pour tomber en F
    isolation_murs:         :non_isole,
    isolation_toiture:      :non_isole,
    isolation_plancher_bas: :non_isole,
    isolation_menuiseries:  :non_isole,
    ventilation:            :aucune_vmc
  }.freeze

  # ──────────────────────────────────────────────────────────────────────
  # 1. ORACLE — reproduit le résultat du Temps 1 via PropertyDpeService
  # ──────────────────────────────────────────────────────────────────────

  test "oracle §7 — gestes [murs, toiture, menuiseries] → F devient D, gain 2" do
    r = PropertyDpeService.call(
      **ORACLE_BASE,
      etat_initial: ORACLE_ETAT_INITIAL,
      gestes: %w[isolation_murs isolation_toiture menuiseries]
    )
    assert_equal "F", r[:classe_avant],
      "classe_avant attendue F, obtenu #{r[:classe_avant]} " \
      "(EP=#{r[:conso_avant][:ep_m2]} CO₂=#{r[:conso_avant][:co2_m2]})"
    assert_equal "D", r[:classe_apres],
      "classe_apres attendue D, obtenu #{r[:classe_apres]} " \
      "(EP=#{r[:conso_apres][:ep_m2]} CO₂=#{r[:conso_apres][:co2_m2]})"
    assert_equal 2, r[:gain_classes]
  end

  # ──────────────────────────────────────────────────────────────────────
  # 2. GESTES INSUFFISANTS — le moteur refuse de promettre une classe
  #    que les gestes ne produisent pas. C'est le sens du chantier.
  # ──────────────────────────────────────────────────────────────────────

  test "gestes insuffisants — menuiseries seules ne doivent PAS atteindre D" do
    r = PropertyDpeService.call(
      **ORACLE_BASE,
      etat_initial: ORACLE_ETAT_INITIAL,
      gestes: %w[menuiseries]
    )
    idx = DpeEngineService::ORDRE_CLASSES
    idx_apres = idx.index(r[:classe_apres])
    idx_d     = idx.index("D")
    assert_operator idx_apres, :>, idx_d,
      "Menuiseries seules ne peuvent pas valoir D ou mieux — " \
      "obtenu #{r[:classe_apres]} (EP=#{r[:conso_apres][:ep_m2]} CO₂=#{r[:conso_apres][:co2_m2]})"
  end

  # ──────────────────────────────────────────────────────────────────────
  # 3. CHAUFFAGE FAIT BASCULER LA CLASSE — double seuil de bout en bout
  # ──────────────────────────────────────────────────────────────────────

  test "isolation seule reste limitée par carbone fioul ; ajout chauffage débloque" do
    sans = PropertyDpeService.call(
      **ORACLE_BASE,
      etat_initial: ORACLE_ETAT_INITIAL,
      gestes: %w[isolation_murs isolation_toiture]
    )
    avec = PropertyDpeService.call(
      **ORACLE_BASE,
      etat_initial: ORACLE_ETAT_INITIAL,
      gestes: %w[isolation_murs isolation_toiture chauffage]
    )
    idx = DpeEngineService::ORDRE_CLASSES
    assert_operator idx.index(avec[:classe_apres]), :<, idx.index(sans[:classe_apres]),
      "Geste chauffage attendu améliorer la classe : sans=#{sans[:classe_apres]} avec=#{avec[:classe_apres]}"
    # Le carbone doit s'effondrer (fioul 0,300 → PAC 0,079)
    assert_operator avec[:conso_apres][:co2_m2], :<, sans[:conso_apres][:co2_m2] / 3.0,
      "Carbone après PAC doit chuter (×~4) : sans=#{sans[:conso_apres][:co2_m2]} avec=#{avec[:conso_apres][:co2_m2]}"
  end

  # ──────────────────────────────────────────────────────────────────────
  # 4. PROCHE_SEUIL — §9 du doc (instabilité ±5 %)
  # ──────────────────────────────────────────────────────────────────────

  test "proche_seuil — oracle §7 lève le drapeau (CO₂ après ~32 kg, seuil D bas 31)" do
    r = PropertyDpeService.call(
      **ORACLE_BASE,
      etat_initial: ORACLE_ETAT_INITIAL,
      gestes: %w[isolation_murs isolation_toiture menuiseries]
    )
    assert r[:proche_seuil],
      "Oracle §7 attendu proche_seuil=true (CO₂=#{r[:conso_apres][:co2_m2]} " \
      "à ~3,5 % du seuil D bas=31)"
  end

  # ──────────────────────────────────────────────────────────────────────
  # 5. EXIGENCE STRUCTURELLE — pas d'invention possible de l'état initial
  # ──────────────────────────────────────────────────────────────────────

  test "appel sans :etat_initial → ArgumentError mentionnant etat_initial" do
    err = assert_raises(ArgumentError) do
      PropertyDpeService.call(
        surface: 120, annee_construction: 1962, zone_climatique: :h1,
        gestes: %w[isolation_murs]
      )
    end
    assert_match(/etat_initial/, err.message,
      "Le message d'erreur doit nommer etat_initial — pas d'invention silencieuse")
  end

  test "etat_initial incomplet (clé manquante) → ArgumentError nommant la clé" do
    etat_incomplet = ORACLE_ETAT_INITIAL.except(:ventilation)
    err = assert_raises(ArgumentError) do
      PropertyDpeService.call(
        **ORACLE_BASE,
        etat_initial: etat_incomplet,
        gestes: []
      )
    end
    assert_match(/ventilation/, err.message,
      "L'erreur doit pointer la clé manquante (ventilation)")
  end

  # ──────────────────────────────────────────────────────────────────────
  # 6. TRACE — détail GV avant/après pour audit (utile dans PR)
  # ──────────────────────────────────────────────────────────────────────

  test "trace audit — détail GV / conso avant / après sur l'oracle" do
    r = PropertyDpeService.call(
      **ORACLE_BASE,
      etat_initial: ORACLE_ETAT_INITIAL,
      gestes: %w[isolation_murs isolation_toiture menuiseries]
    )
    puts
    puts "  [TRACE]  gestes appliqués : isolation_murs, isolation_toiture, menuiseries"
    puts "  [AVANT]  GV=#{r[:detail][:gv_avant]} W/K  " \
         "breakdown=#{r[:detail][:breakdown_avant].inspect}"
    puts "  [AVANT]  → EP=#{r[:conso_avant][:ep_m2]} kWhEP/m²/an  " \
         "CO₂=#{r[:conso_avant][:co2_m2]} kg/m²/an  classe=#{r[:classe_avant]}"
    puts "  [APRÈS]  GV=#{r[:detail][:gv_apres]} W/K  " \
         "breakdown=#{r[:detail][:breakdown_apres].inspect}"
    puts "  [APRÈS]  → EP=#{r[:conso_apres][:ep_m2]} kWhEP/m²/an  " \
         "CO₂=#{r[:conso_apres][:co2_m2]} kg/m²/an  classe=#{r[:classe_apres]}"
    puts "  [GAIN]   #{r[:gain_classes]} classes  |  proche_seuil=#{r[:proche_seuil]}"
    puts "  [ÉTAT]   apres=#{r[:detail][:etat_apres].inspect}"

    assert r[:detail][:gv_apres] < r[:detail][:gv_avant]
    assert r[:detail][:etat_apres][:isolation_murs] == :isole
    assert r[:detail][:etat_apres][:energie_chauffage] == :fioul  # chauffage non coché
  end

  # ──────────────────────────────────────────────────────────────────────
  # 7. GESTE CHAUFFE_EAU — plus un no-op, câblé au moteur via type_ecs
  # ──────────────────────────────────────────────────────────────────────
  # Le geste installe un CET électrique (COP_ECS ≈ 2,5). Effet moteur :
  # conso ECS passe du forfait de l'énergie de chauffage (15 kWhEF/m²
  # gaz/fioul, 17 élec) au forfait :pac (7 kWhEF/m²) ET les facteurs EP/CO2
  # bascullent sur l'électricité pour ce flux.

  ORACLE_ETAT_INITIAL_GAZ = ORACLE_ETAT_INITIAL.merge(energie_chauffage: :gaz).freeze

  test "chauffe_eau : ep_m2 STRICT inf à sans (bien gaz, gain modéré ~1,7 kWhEP/m²)" do
    sans = PropertyDpeService.call(
      **ORACLE_BASE, etat_initial: ORACLE_ETAT_INITIAL_GAZ, gestes: []
    )
    avec = PropertyDpeService.call(
      **ORACLE_BASE, etat_initial: ORACLE_ETAT_INITIAL_GAZ, gestes: %w[chauffe_eau]
    )
    assert_operator avec[:conso_apres][:ep_m2], :<, sans[:conso_apres][:ep_m2],
      "chauffe_eau doit désormais réduire ep_m2 " \
      "(sans=#{sans[:conso_apres][:ep_m2]} avec=#{avec[:conso_apres][:ep_m2]})"
    delta_ep = sans[:conso_apres][:ep_m2] - avec[:conso_apres][:ep_m2]
    assert_in_delta 1.7, delta_ep, 0.3,
      "Delta EP CET sur gaz attendu ~1,7 kWhEP/m² (obtenu #{delta_ep})"
    # Bénéfice principal du CET sur gaz : le CO2 (élec 0,079 vs gaz 0,234).
    delta_co2 = sans[:conso_apres][:co2_m2] - avec[:conso_apres][:co2_m2]
    assert_in_delta 2.96, delta_co2, 0.3,
      "Delta CO2 CET sur gaz attendu ~3 kgCO2/m² (obtenu #{delta_co2})"
  end

  test "chauffage + chauffe_eau : IDENTIQUE à chauffage seul (anti-double-compte)" do
    # Le geste chauffage bascule energie_chauffage à :pac. À ce moment,
    # la PAC couvre déjà l'ECS (ECS_FORFAIT_EF[:pac] = 7 kWhEF/m²).
    # Ajouter chauffe_eau (type_ecs: :cet) laisse energie_ecs = :pac — le
    # moteur voit le même mode. Aucun gain supplémentaire, aucun cumul.
    sans_ce = PropertyDpeService.call(
      **ORACLE_BASE, etat_initial: ORACLE_ETAT_INITIAL_GAZ,
      gestes: %w[chauffage]
    )
    avec_ce = PropertyDpeService.call(
      **ORACLE_BASE, etat_initial: ORACLE_ETAT_INITIAL_GAZ,
      gestes: %w[chauffage chauffe_eau]
    )
    assert_equal sans_ce[:conso_apres][:ep_m2],  avec_ce[:conso_apres][:ep_m2],
      "chauffage seul et chauffage+chauffe_eau doivent donner le MÊME EP " \
      "(la PAC couvre déjà l'ECS) — sinon double-compte."
    assert_equal sans_ce[:conso_apres][:co2_m2], avec_ce[:conso_apres][:co2_m2]
  end

  test "ordre chauffage / chauffe_eau indifférent (reduce commutatif sur ces gestes)" do
    a = PropertyDpeService.call(
      **ORACLE_BASE, etat_initial: ORACLE_ETAT_INITIAL_GAZ,
      gestes: %w[chauffage chauffe_eau]
    )
    b = PropertyDpeService.call(
      **ORACLE_BASE, etat_initial: ORACLE_ETAT_INITIAL_GAZ,
      gestes: %w[chauffe_eau chauffage]
    )
    assert_equal a[:conso_apres][:ep_m2],  b[:conso_apres][:ep_m2]
    assert_equal a[:conso_apres][:co2_m2], b[:conso_apres][:co2_m2]
  end

  test "chauffe_eau seul sur électricité : delta EP fort (~19 kWhEP/m²)" do
    # Sur bâti chauffé à l'électricité, cumulus (17 × 1,9 = 32,3 kWhEP/m²)
    # → CET (7 × 1,9 = 13,3 kWhEP/m²) : ~19 kWhEP/m² gagnés. C'est là que
    # le geste chauffe_eau justifie sa présence dans la liste des macro-postes.
    etat_elec = ORACLE_ETAT_INITIAL.merge(energie_chauffage: :electricite)
    sans = PropertyDpeService.call(**ORACLE_BASE, etat_initial: etat_elec, gestes: [])
    avec = PropertyDpeService.call(**ORACLE_BASE, etat_initial: etat_elec, gestes: %w[chauffe_eau])
    delta_ep = sans[:conso_apres][:ep_m2] - avec[:conso_apres][:ep_m2]
    assert_in_delta 19.0, delta_ep, 1.0,
      "Delta EP CET vs cumulus élec attendu ~19 kWhEP/m² (obtenu #{delta_ep})"
  end

  # Physique : la combinaison chauffage+chauffe_eau ne peut JAMAIS rendre
  # un ep_m2 inférieur à chauffage seul (invariant demandé par le user).
  # Ce test le vérifie sur un bien fioul (le geste chauffage bascule à
  # PAC, comme sur gaz).
  test "invariant physique : ep_m2(chauffage+chauffe_eau) >= ep_m2(chauffage seul)" do
    seul = PropertyDpeService.call(
      **ORACLE_BASE, etat_initial: ORACLE_ETAT_INITIAL,
      gestes: %w[chauffage]
    )
    combo = PropertyDpeService.call(
      **ORACLE_BASE, etat_initial: ORACLE_ETAT_INITIAL,
      gestes: %w[chauffage chauffe_eau]
    )
    assert_operator combo[:conso_apres][:ep_m2], :>=, seul[:conso_apres][:ep_m2],
      "combo(#{combo[:conso_apres][:ep_m2]}) ne doit pas passer sous seul(#{seul[:conso_apres][:ep_m2]}) — " \
      "un CET redondant ne peut pas économiser d'énergie qui n'existe pas."
  end
end
