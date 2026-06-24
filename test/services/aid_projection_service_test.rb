require "test_helper"
require_relative "../support/aid_rules_helper"

# Tests des 4 GARDE-FOUS critiques d'AidProjectionService.
#
# Le bug auto-snap d'hier (la cible serveur sautait toute seule à B sans
# clic utilisateur) ne doit PAS régresser. Et la projection ne doit JAMAIS
# promettre un montant qui n'est pas réellement débloquable.
#
# Garde-fous :
#   1. LECTURE SEULE : appeler la projection ne change pas la cible
#   2. REVENUS MANQUANTS : pas de promesse trompeuse
#   3. DÉJÀ OPTIMAL : pas de faux espoir
#   4. CAS NOMINAL : invitation visible, total courant INCHANGÉ
class AidProjectionServiceTest < ActiveSupport::TestCase
  include AidRulesHelper

  setup do
    seed_aid_rules!
  end

  # ─── 1. LECTURE SEULE — garde-fou anti-persistance ────────────────────

  test "projection ne mute PAS dpe_target en mémoire" do
    property = build_grand_nancy_property(dpe_target: "C")
    property.surface_ite     = 80
    property.surface_iti     = 30
    property.vmc_double_flux = true

    current_total = AidCalculatorService.new(property).call[:total_subventions].to_i

    AidProjectionService.call(property, current_total: current_total)

    assert_equal "C", property.dpe_target,
                 "La cible DPE en mémoire doit rester celle du serveur, jamais sautée par la projection"
  end

  test "projection n'ajoute AUCUN nouveau changement sur dpe_target" do
    # Property.new(dpe_target: "C") a déjà dpe_target_changed? = true par
    # construction (nil → "C" vs default). On ne peut donc pas comparer
    # directement à false. Le bon test est : la projection ne doit pas
    # AJOUTER de changement par-dessus l'état initial.
    property = build_grand_nancy_property(dpe_target: "C")
    property.surface_ite     = 80
    property.surface_iti     = 30
    property.vmc_double_flux = true

    snapshot_changes = property.changes.deep_dup

    current_total = AidCalculatorService.new(property).call[:total_subventions].to_i
    AidProjectionService.call(property, current_total: current_total)

    assert_equal snapshot_changes["dpe_target"], property.changes["dpe_target"],
                 "La projection ne doit pas modifier l'état dirty de dpe_target. " \
                 "Si ce delta change, un save() ultérieur persisterait B (bug auto-snap d'hier). " \
                 "Avant : #{snapshot_changes["dpe_target"].inspect}, après : #{property.changes["dpe_target"].inspect}"
  end

  # ─── 2. REVENUS MANQUANTS — pas de promesse trompeuse ────────────────

  test "income_bracket nil → projection retourne nil (aucune invitation à afficher)" do
    property = build_grand_nancy_property(dpe_target: "C", income_bracket: nil)
    property.surface_ite     = 80
    property.surface_iti     = 30
    property.vmc_double_flux = true

    current_total = AidCalculatorService.new(property).call[:total_subventions].to_i

    projection = AidProjectionService.call(property, current_total: current_total)

    assert_nil projection,
               "Sans revenus renseignés, MPR/GN sont aussi à 0 à toute cible — il ne faut pas promettre un delta inexistant. Reçu : #{projection.inspect}"
  end

  # ─── 3. DÉJÀ OPTIMAL — pas de faux espoir ────────────────────────────

  test "dpe_target = A → projection retourne nil (rien au-dessus)" do
    property = build_grand_nancy_property(dpe_target: "A")
    property.surface_ite     = 80
    property.surface_iti     = 30
    property.vmc_double_flux = true

    current_total = AidCalculatorService.new(property).call[:total_subventions].to_i
    projection    = AidProjectionService.call(property, current_total: current_total)

    assert_nil projection, "Cible A est le plafond — aucune cible supérieure à proposer"
  end

  test "viser une cible supérieure n'apporte rien → projection retourne nil" do
    # Bien hors Grand Nancy, hors parcours accompagné : MPR Par geste donne
    # un forfait pac_air_eau qui ne dépend pas de la cible. Passer de D à C
    # à B à A ne change rien au total → on doit rester silencieux.
    property = Property.new(
      address: "1 rue de Test", city: "Paris", zipcode: "75001", code_insee: "75056",
      surface: 60.0, property_type: "appartement", construction_year: 1970,
      dpe_class: "D", dpe_target: "C", income_bracket: "intermediaire",
      equipements_selection: {}, travaux_selection: {}
    )
    property.pac_air_eau = true

    current_total = AidCalculatorService.new(property).call[:total_subventions].to_i
    projection    = AidProjectionService.call(property, current_total: current_total)

    assert_nil projection,
               "Si aucune cible plus ambitieuse ne débloque d'aide en plus, on ne propose rien. Reçu : #{projection.inspect} (current_total=#{current_total})"
  end

  # ─── 4. CAS NOMINAL — invitation visible, total courant INCHANGÉ ─────

  test "Grand Nancy, F→C avec parcours accompagné → projection propose B avec delta > 0" do
    property = build_grand_nancy_property(dpe_class: "F", dpe_target: "C")
    property.surface_ite     = 80   # geste isolation #1
    property.surface_iti     = 30   # geste isolation #2
    property.vmc_double_flux = true # déclenche parcours accompagné

    current_result = AidCalculatorService.new(property).call
    current_total  = current_result[:total_subventions].to_i

    projection = AidProjectionService.call(property, current_total: current_total)

    assert_not_nil projection,
                   "Cas nominal : MPR Ampleur déjà calculée à C, mais Grand Nancy Réno Globale n'est qu'en potentielle. À B elle bascule en subvention → delta > 0 attendu."
    assert_equal "B", projection[:target],
                 "On doit proposer la cible SUPÉRIEURE LA PLUS PROCHE qui débloque (B avant A)"
    assert_operator projection[:delta], :>, 0,
                    "delta strictement positif obligatoire (le calcul à B inclut une aide que C n'a pas)"
    assert_equal projection[:total] - current_total, projection[:delta],
                 "delta = total projeté − total courant (cohérence arithmétique)"
  end

  test "le total courant n'est PAS contaminé par la projection (aides courantes inchangées)" do
    property = build_grand_nancy_property(dpe_class: "F", dpe_target: "C")
    property.surface_ite     = 80
    property.surface_iti     = 30
    property.vmc_double_flux = true

    # Mesure AVANT projection
    total_avant = AidCalculatorService.new(property).call[:total_subventions].to_i

    # Appel projection
    AidProjectionService.call(property, current_total: total_avant)

    # Mesure APRÈS projection — doit être identique au pixel près.
    total_apres = AidCalculatorService.new(property).call[:total_subventions].to_i

    assert_equal total_avant, total_apres,
                 "Le total à la cible courante (#{property.dpe_target}) doit être INCHANGÉ après projection. " \
                 "Si ce test casse, la projection contamine l'état partagé (mutation d'instance, cache, etc.)."
  end

  # ─── Helper ──────────────────────────────────────────────────────────

  private

  def build_grand_nancy_property(attrs = {})
    defaults = {
      address:           "Place Stanislas",
      city:              "Nancy",
      zipcode:           "54000",
      code_insee:        "54395",   # Nancy, source GrandNancy::COMMUNES
      surface:           100.0,
      property_type:     "maison",
      construction_year: 1970,
      dpe_class:         "F",
      dpe_target:        "C",
      income_bracket:    "modeste",
      equipements_selection: {},
      travaux_selection:     {}
    }
    Property.new(defaults.merge(attrs))
  end
end
