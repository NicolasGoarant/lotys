require "test_helper"
require_relative "../support/aid_rules_helper"

# ═══════════════════════════════════════════════════════════════════════
#   AidCalculatorService — cas Grand Nancy.
#
#   Test critique pour la mise en relation ALEC : on vérifie qu'une
#   maison Grand Nancy éligible à MaPrimeRénov' Parcours accompagné
#   reçoit À LA FOIS :
#     - une subvention nationale (MPR ou CEE)
#     - une subvention LOCALE Grand Nancy non vide
#
#   Si la couche locale sort vide alors que les inputs sont conformes,
#   le test ÉCHOUE — c'est le risque "LocalAidCalculator inerte / aide
#   territoriale non câblée" qu'on veut détecter AVANT envoi à l'ALEC.
# ═══════════════════════════════════════════════════════════════════════
class AidCalculatorGrandNancyTest < ActiveSupport::TestCase
  include AidRulesHelper

  setup do
    seed_aid_rules!
  end

  # ── Cas canonique : Nancy, F→B, maison, modeste, ITE+ITI+VMC ────────
  # → eligible_parcours_accompagne? = true (≥2 gestes isolation + VMC + saut 4)
  # → calculate_mpr_ampleur ajoute une subvention MPR
  # → calculate_grand_nancy_renovation_globale ajoute une subvention locale
  # → calculate_grand_nancy_isolation est skipée (eligible_parcours_accompagne)
  test "maison Grand Nancy en rénovation d'ampleur reçoit MPR + aide locale Grand Nancy" do
    property = build_grand_nancy_property(
      dpe_class:     "F",
      dpe_target:    "B",
      property_type: "maison"
    )
    property.surface_ite      = 80   # geste isolation #1
    property.surface_iti      = 30   # geste isolation #2
    property.vmc_double_flux  = true

    result = AidCalculatorService.new(property).call

    # 1. Aides nationales : au moins une (MPR Ampleur en l'occurrence).
    aides_nationales = result[:subventions].select { |a| %w[mpr cee].include?(a[:type]) }
    assert aides_nationales.any?,
      "Devrait avoir au moins une aide nationale (MPR/CEE). " \
      "Reçu : subventions=#{result[:subventions].map { |a| a[:type] }.inspect}, " \
      "errors=#{result[:errors].inspect}"

    # 2. Aides LOCALES Grand Nancy : DOIVENT exister et être non vides.
    #    C'est le test ALEC. Si ça passe à 0, c'est un vrai bug : soit
    #    territory_grand_nancy? ne reconnaît pas le code INSEE, soit la
    #    branche Grand Nancy renvoie 0 €.
    aides_locales = result[:subventions].select { |a| a[:type] == "local" }
    assert aides_locales.any?,
      "AIDE LOCALE GRAND NANCY MANQUANTE : aucune subvention :type=>'local' " \
      "alors que les conditions sont réunies (code_insee=#{property.code_insee}, " \
      "property_type=maison, dpe_class=F, dpe_target=B, parcours_accompagne=oui). " \
      "Subventions reçues : #{result[:subventions].map { |a| [a[:type], a[:name]] }.inspect}"

    aide_locale = aides_locales.first
    assert_operator aide_locale[:amount], :>, 0,
      "L'aide locale Grand Nancy devrait être > 0 €, reçu : #{aide_locale.inspect}"
  end

  # ── Cas "isolation seule" : F→C, pas de parcours accompagné ─────────
  # → calculate_grand_nancy_isolation devrait s'activer (cible C, maison,
  #   surfaces > 0). Vérifie le 2e canal d'aide locale Grand Nancy.
  test "maison Grand Nancy en isolation seule (hors parcours accompagné) reçoit aide isolation Grand Nancy" do
    property = build_grand_nancy_property(
      dpe_class:     "F",
      dpe_target:    "C",
      property_type: "maison"
    )
    # Surfaces isolation MAIS pas de VMC → pas de parcours accompagné.
    property.surface_ite              = 100
    property.surface_combles_perdus   = 50

    result = AidCalculatorService.new(property).call

    aides_locales = result[:subventions].select { |a| a[:type] == "local" }
    assert aides_locales.any?,
      "AIDE LOCALE GRAND NANCY ISOLATION MANQUANTE : aucune subvention :type=>'local' " \
      "alors que le bien remplit les conditions Grand Nancy Isolation " \
      "(maison, code_insee=#{property.code_insee}, dpe_target=C, ITE+combles perdus). " \
      "Subventions reçues : #{result[:subventions].map { |a| [a[:type], a[:name]] }.inspect}, " \
      "errors=#{result[:errors].inspect}"

    assert_operator aides_locales.sum { |a| a[:amount] }, :>, 0,
      "L'aide locale Grand Nancy Isolation devrait être > 0 €, reçu : #{aides_locales.inspect}"
  end

  # ── Garde-fou : hors Grand Nancy, pas d'aide locale ────────────────
  # Sanity check : sans territoire, on n'invente pas une aide locale.
  test "maison hors Grand Nancy ne reçoit aucune aide locale" do
    property = build_grand_nancy_property(
      dpe_class:     "F",
      dpe_target:    "C",
      property_type: "maison"
    )
    property.code_insee  = "75056" # Paris, hors Grand Nancy
    property.surface_ite = 100

    result = AidCalculatorService.new(property).call

    aides_locales = result[:subventions].select { |a| a[:type] == "local" }
    assert_empty aides_locales,
      "Hors Grand Nancy, aucune subvention locale ne devrait être renvoyée. " \
      "Reçu : #{aides_locales.inspect}"
  end

  private

  # Construit une Property Grand Nancy en mémoire (pas de save), avec les
  # defaults qui activent les branches Grand Nancy. À surcharger via attrs
  # selon le scénario.
  def build_grand_nancy_property(attrs = {})
    defaults = {
      address:           "Place Stanislas",
      city:              "Nancy",
      zipcode:           "54000",
      code_insee:        "54395", # Nancy, source GrandNancy::COMMUNES
      surface:           100.0,
      property_type:     "maison",
      construction_year: 1970,
      income_bracket:    "modeste",
      equipements_selection: {},
      travaux_selection:     {}
    }
    Property.new(defaults.merge(attrs))
  end
end
