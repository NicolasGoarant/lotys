require "test_helper"
require_relative "../support/aid_rules_helper"

# Durcissement du mode de panne « règle absente en DB » d'AidCalculatorService.
#
# Avant ce commit, chaque méthode de calcul faisait :
#     rule = AidRule.find_by(slug: "xxx", active: true)
#     return unless rule
# → la branche disparaissait en silence si la rule n'était pas seedée
# (panne aid_rules vide observée en prod). Aucune trace, ni log, ni
# @errors, ni signal côté UI. Cf. db/seeds_local_aids.rb pour la
# réparation, et fetch_rule! pour le durcissement.
#
# Ces tests prouvent que la même classe d'omission ne peut plus être
# silencieuse à l'avenir :
#   1. signal côté @errors (préfixe "[interne]")
#   2. signal côté logs (Rails.logger.error)
#   3. pas de faux positif : un profil non-éligible métier ne déclenche
#      PAS l'entrée [interne]
class AidRuleAbsenceTest < ActiveSupport::TestCase
  include AidRulesHelper

  setup do
    seed_aid_rules!
  end

  # Bien éligible parcours accompagné : F→C, modeste, ITE+ITI+VMC →
  # déclenche calculate_mpr_ampleur, qui appelle fetch_rule!("mpr_parcours_accompagne").
  def build_eligible_property
    p = Property.new(
      address: "1 rue Test", city: "Nancy", zipcode: "54000", code_insee: "54395",
      surface: 100, property_type: "maison", construction_year: 1970,
      dpe_class: "F", dpe_target: "C", income_bracket: "modeste",
      equipements_selection: {}, travaux_selection: {}
    )
    p.surface_ite      = 80
    p.surface_iti      = 30
    p.vmc_double_flux  = true
    p
  end

  # ─── 1. SIGNAL CÔTÉ @errors ──────────────────────────────────────────

  test "rule mpr_parcours_accompagne absente → @errors contient une entrée [interne] qui nomme le slug" do
    AidRule.find_by(slug: "mpr_parcours_accompagne").destroy
    result = AidCalculatorService.new(build_eligible_property).call

    interne_errors = result[:errors].select { |e| e.to_s.start_with?("[interne]") }
    assert interne_errors.any?,
           "@errors devrait contenir au moins une entrée [interne], reçu : #{result[:errors].inspect}"
    assert_match(/mpr_parcours_accompagne/, interne_errors.first,
                 "L'entrée [interne] doit nommer le slug manquant")
  end

  test "rule eco_ptz absente → @errors signale eco_ptz" do
    AidRule.find_by(slug: "eco_ptz").destroy
    result = AidCalculatorService.new(build_eligible_property).call

    assert result[:errors].any? { |e| e.start_with?("[interne]") && e.include?("eco_ptz") },
           "@errors devrait signaler eco_ptz manquant, reçu : #{result[:errors].inspect}"
  end

  test "rule grand_nancy_renovation_globale absente → @errors signale ce slug" do
    AidRule.find_by(slug: "grand_nancy_renovation_globale").destroy
    result = AidCalculatorService.new(build_eligible_property).call

    assert result[:errors].any? { |e| e.start_with?("[interne]") && e.include?("grand_nancy_renovation_globale") },
           "@errors devrait signaler grand_nancy_renovation_globale, reçu : #{result[:errors].inspect}"
  end

  # ─── 2. SIGNAL CÔTÉ LOGS (Rails.logger.error) ────────────────────────

  test "rule absente → Rails.logger.error est appelé avec le slug et l'instruction de re-seed" do
    AidRule.find_by(slug: "mpr_parcours_accompagne").destroy

    log_io          = StringIO.new
    original_logger = Rails.logger
    Rails.logger    = ActiveSupport::Logger.new(log_io)

    AidCalculatorService.new(build_eligible_property).call

    assert_match(/\[AidCalculator\] règle absente en DB: mpr_parcours_accompagne/, log_io.string,
                 "Le log doit nommer le slug manquant")
    assert_match(/seeds_local_aids/, log_io.string,
                 "Le log doit pointer vers le seed à relancer (instruction actionnable côté Heroku)")
  ensure
    Rails.logger = original_logger
  end

  # ─── 3. NON-RÉGRESSION : pas de faux positif sur erreur métier ───────

  test "profil non-éligible métier (DPE D, exigence MPR Ampleur E/F/G) → AUCUNE entrée [interne]" do
    # Toutes les rules sont en DB (setup seed_aid_rules!) — il n'y a donc
    # rigoureusement aucune raison technique d'avoir [interne] dans @errors.
    # On force le passage par calculate_mpr_ampleur via D→A (saut 3,
    # parcours accompagné déclenché), mais DPE D hors E/F/G → l'erreur
    # métier "réservée aux logements E, F ou G" est émise normalement.
    p = build_eligible_property
    p.dpe_class  = "D"
    p.dpe_target = "A"

    result = AidCalculatorService.new(p).call

    interne_errors = result[:errors].select { |e| e.to_s.start_with?("[interne]") }
    assert interne_errors.empty?,
           "Aucune entrée [interne] attendue quand toutes les rules sont en DB. " \
           "Reçu : #{interne_errors.inspect}. (Erreurs métier acceptables : #{result[:errors].inspect})"

    # Sanity : l'erreur métier d'éligibilité, elle, doit bien être présente
    # pour confirmer qu'on ne teste pas un cas où le calcul ne se déclenche
    # même pas.
    assert result[:errors].any? { |e| e.include?("E, F ou G") },
           "L'erreur métier attendue ('réservée aux logements E, F ou G') devrait être présente. " \
           "Reçu : #{result[:errors].inspect}"
  end

  test "profil avec revenus manquants → erreur métier MPR/CEE, pas [interne]" do
    p = build_eligible_property
    p.income_bracket = nil

    result = AidCalculatorService.new(p).call

    interne_errors = result[:errors].select { |e| e.to_s.start_with?("[interne]") }
    assert interne_errors.empty?,
           "Revenus manquants est une erreur métier, pas une panne technique. Aucune [interne] attendue. " \
           "Reçu : #{interne_errors.inspect}"
    assert result[:errors].any? { |e| e.include?("Revenus non renseignés") },
           "L'erreur métier 'Revenus non renseignés' devrait être présente. " \
           "Reçu : #{result[:errors].inspect}"
  end

  # ─── 4. FAUX POSITIF INVERSE — règle ABSENTE + profil non-éligible ──
  #
  # Tests test-first : tant que fetch_rule! est appelé AVANT le filtre
  # d'éligibilité métier de la même méthode, un profil destiné à être
  # rejeté en métier sera doublement pénalisé d'une fausse erreur [interne].
  # C'est un bruit interne trompeur pour le mainteneur.
  # Ces 3 tests doivent ÉCHOUER sur le code actuel, et PASSER après le
  # réordonnancement.

  test "faux positif #1 : mpr_parcours_accompagne absente + bien D→A (non-éligible E/F/G) → AUCUN [interne]" do
    AidRule.find_by(slug: "mpr_parcours_accompagne").destroy
    p = build_eligible_property
    p.dpe_class  = "D"
    p.dpe_target = "A"

    result = AidCalculatorService.new(p).call

    interne_errors = result[:errors].select { |e| e.to_s.start_with?("[interne]") }
    assert interne_errors.empty?,
           "Bien D→A non-éligible métier (DPE pas E/F/G) → la branche aurait été rejetée " \
           "métier de toute façon, [interne] ne doit PAS être poussé. " \
           "Reçu : #{interne_errors.inspect}. Erreurs complètes : #{result[:errors].inspect}"
  end

  test "faux positif #2 : eco_ptz absente + bien < 2 ans (non-éligible ancienneté) → AUCUN [interne]" do
    AidRule.find_by(slug: "eco_ptz").destroy
    p = build_eligible_property
    p.construction_year = Date.today.year - 1   # < 2 ans → erreur métier "achevé depuis ≥ 2 ans"

    result = AidCalculatorService.new(p).call

    interne_errors = result[:errors].select { |e| e.to_s.start_with?("[interne]") && e.include?("eco_ptz") }
    assert interne_errors.empty?,
           "Bien < 2 ans non-éligible eco_ptz → [interne] ne doit PAS être poussé. " \
           "Reçu : #{interne_errors.inspect}. Erreurs complètes : #{result[:errors].inspect}"
  end

  test "faux positif #3 : grand_nancy_isolation absente + bien GN maison mais cible D → AUCUN [interne]" do
    AidRule.find_by(slug: "grand_nancy_isolation").destroy
    p = build_eligible_property
    # On veut atteindre calculate_grand_nancy_isolation : GN + maison ✓.
    # On veut être REJETÉ par le check %w[A B C] : on met dpe_target "D".
    # On veut aussi éviter eligible_parcours_accompagne? (sinon la branche
    # est skipée encore avant) : on décoche la VMC pour casser l'éligibilité.
    p.dpe_target       = "D"
    p.vmc_double_flux  = false   # casse eligible_parcours_accompagne? (saut + isolation + ventilation)

    result = AidCalculatorService.new(p).call

    interne_errors = result[:errors].select { |e| e.to_s.start_with?("[interne]") && e.include?("grand_nancy_isolation") }
    assert interne_errors.empty?,
           "Bien GN + maison + cible D (non-éligible métier au check A/B/C) → " \
           "[interne] ne doit PAS être poussé pour grand_nancy_isolation. " \
           "Reçu : #{interne_errors.inspect}. Erreurs complètes : #{result[:errors].inspect}"
  end

  # ─── 5. TOLÉRANT — verrou du contrat fallback ────────────────────────
  #
  # Les 3 sites tolérants (rule&.slug || "fallback" pour cee dans MPR
  # Ampleur, mpr_par_geste et cee dans Par geste) doivent continuer à
  # produire des subventions correctes même si leur rule est absente.
  # Si quelqu'un demain les transforme en `return unless rule`, ce test
  # le détectera.

  test "tolérant : cee absente + profil éligible CEE → la ligne CEE sort quand même avec amount > 0 et aucun [interne]" do
    AidRule.find_by(slug: "cee").destroy
    # Profil qui FORCE le passage par calculate_mpr_par_geste_and_cee
    # (saut < 2 → pas parcours accompagné). PAC air/eau → forfait CEE
    # non nul pour tout bracket.
    p = build_eligible_property
    p.dpe_target      = "E"          # F→E = saut 1 → pas parcours accompagné
    p.vmc_double_flux = false
    p.pac_air_eau     = true         # déclenche les forfaits MPR Par geste ET CEE

    result = AidCalculatorService.new(p).call

    cee_sub = result[:subventions].find { |s| s[:type] == "cee" }
    assert_not_nil cee_sub,
                   "Une ligne CEE doit être produite via le fallback hardcoded (rule&.slug || \"cee\"). " \
                   "Subventions reçues : #{result[:subventions].map { |s| [s[:type], s[:amount]] }.inspect}, " \
                   "errors : #{result[:errors].inspect}"
    assert_operator cee_sub[:amount], :>, 0,
                    "Le montant CEE doit être > 0 sur un profil avec PAC. Reçu : #{cee_sub.inspect}"

    interne_errors = result[:errors].select { |e| e.to_s.start_with?("[interne]") && e.include?("cee") }
    assert interne_errors.empty?,
           "cee est un site TOLÉRANT (fallback hardcoded), aucun [interne] n'est attendu pour ce slug. " \
           "Reçu : #{interne_errors.inspect}"
  end

  # ─── 6. COMPLÉMENT — 4e slug bloquant manquant dans la batterie initiale ─

  test "rule grand_nancy_isolation absente + profil ÉLIGIBLE → @errors signale ce slug" do
    AidRule.find_by(slug: "grand_nancy_isolation").destroy
    # Profil qui atteint réellement calculate_grand_nancy_isolation et
    # passe ses filtres métier : GN + maison + PAS parcours accompagné +
    # cible C + ITE/combles > 0.
    p = build_eligible_property
    p.dpe_target              = "C"      # OK au check A/B/C
    p.vmc_double_flux         = false    # casse parcours accompagné
    p.surface_combles_perdus  = 60       # surface > 0 pour le calcul

    result = AidCalculatorService.new(p).call

    assert result[:errors].any? { |e| e.start_with?("[interne]") && e.include?("grand_nancy_isolation") },
           "@errors devrait signaler grand_nancy_isolation manquant pour un profil éligible. " \
           "Reçu : #{result[:errors].inspect}"
  end
end
