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
end
