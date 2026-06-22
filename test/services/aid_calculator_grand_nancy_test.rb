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

  # ── Câblage UI : cocher les macros suffit (via TravauxDefaultsDeriver) ─
  # Cas critique du bug "Aucune aide retenue pour le moment" en prod : DPE E→A,
  # foyer intermédiaire (RFR ≈ 25 000 / 1 personne), bien à Nancy, l'utilisateur
  # n'a coché QUE les cases macro et n'a aucune donnée mesurée dans surface_ite,
  # vmc_double_flux, etc.
  #
  # Avant l'introduction du déricteur, AidCalculatorService renvoyait
  # subventions=[] car travaux_prevus était vide. On vérifie maintenant que :
  #   1. cocher les macros déclenche le dépôt d'estimations par défaut ;
  #   2. le drapeau inputs_estimes est posé pour que la vue affiche le bandeau ;
  #   3. MPR Ampleur ET Grand Nancy Rénovation Globale sortent non vides.
  test "cocher les macros E→A intermédiaire Grand Nancy débloque MPR + aide locale" do
    property = build_grand_nancy_property(
      dpe_class:      "E",
      dpe_target:     "A",
      property_type:  "maison",
      income_bracket: "intermediaire"
    )
    # Pas d'injection de surface_ite, surface_iti, vmc_double_flux, etc.
    # Tout passe par les 7 cases macro, comme dans la card "Rénovation
    # énergétique" en prod.
    property.travaux_selection = {
      "isolation_toiture" => true,
      "isolation_murs"    => true,
      "vmc"               => true,
      "chauffage"         => true
    }

    derived = TravauxDefaultsDeriver.new(property).call!
    assert derived, "Le déricteur doit signaler qu'une estimation a été déposée"

    # Les colonnes structurées attendues par le service ont bien été remplies
    # par des estimations par défaut (mais ne se prétendent pas mesurées).
    assert_operator property.surface_combles_perdus.to_f, :>, 0,
                    "isolation_toiture coché doit produire surface_combles_perdus > 0"
    assert_operator property.surface_ite.to_f, :>, 0,
                    "isolation_murs coché doit produire surface_ite > 0"
    assert property.vmc_double_flux, "vmc coché doit activer vmc_double_flux"
    assert property.pac_air_eau, "chauffage coché doit activer pac_air_eau par défaut"

    # Marqueur d'estimation : la vue doit pouvoir afficher le bandeau honnête.
    assert_equal true, (property.equipements_selection || {})["inputs_estimes"],
                 "Le drapeau inputs_estimes doit être posé après dérivation"

    # Calcul des aides via le même chemin que le contrôleur : travaux_actifs
    # passé au service comme filtre macros.
    result = AidCalculatorService.new(
      property,
      travaux_actifs: property.travaux_actifs
    ).call

    aides_nationales = result[:subventions].select { |a| %w[mpr cee].include?(a[:type]) }
    assert aides_nationales.any?,
           "MPR (Ampleur) attendue après dérivation. Reçu : " \
           "subventions=#{result[:subventions].map { |a| [a[:type], a[:slug]] }.inspect}, " \
           "errors=#{result[:errors].inspect}"
    assert_operator aides_nationales.sum { |a| a[:amount] }, :>, 0,
                    "Le montant national doit être > 0"

    aides_locales = result[:subventions].select { |a| a[:type] == "local" }
    assert aides_locales.any?,
           "Aide locale Grand Nancy attendue après dérivation. Reçu : " \
           "subventions=#{result[:subventions].map { |a| [a[:type], a[:slug]] }.inspect}"
    assert_operator aides_locales.sum { |a| a[:amount] }, :>, 0,
                    "Le montant local doit être > 0"
  end

  # ── Priorité : une mesure existante ne doit JAMAIS être écrasée ─────
  # Si Claude a déjà rempli surface_ite (mesure issue d'un DPE / devis),
  # le déricteur doit la respecter et ne PAS déposer une estimation à la place.
  test "le déricteur ne touche pas à une surface déjà mesurée" do
    property = build_grand_nancy_property(
      dpe_class:      "E",
      dpe_target:     "A",
      property_type:  "maison",
      income_bracket: "intermediaire"
    )
    property.surface_ite = 42.0  # mesure existante (Claude / saisie user)
    property.travaux_selection = { "isolation_murs" => true }

    TravauxDefaultsDeriver.new(property).call!

    assert_in_delta 42.0, property.surface_ite.to_f, 0.01,
                    "Une surface mesurée ne doit pas être remplacée par un default"
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
