require "test_helper"

# Tests du service de calcul des aides.
# Objectif : valider la logique de filtrage travaux_actifs introduite au
# chantier 3, ainsi que quelques cas d'erreur canoniques.
#
# Stratégie : on construit des Property en mémoire via Property.new sans
# appel à save. Le service lit les attributs, il ne persiste jamais.
# Les associations (analysis, device_simulation, local_aid_results) sont
# laissées nil — le service gère gracieusement ces cas avec des &. partout.

class AidCalculatorServiceTest < ActiveSupport::TestCase

  # Slugs d'AidRule utilisés par le service. Le service fait des
  # AidRule.find_by(slug: "...", active: true) et retourne early si absent.
  # On les seed dans setup pour que les tests n'en dépendent pas.
  SLUGS_REQUIS = %w[
    mpr_parcours_accompagne
    mpr_par_geste
    cee
    eco_ptz
    grand_nancy_isolation
    grand_nancy_renovation_globale
  ].freeze

  def setup
    SLUGS_REQUIS.each do |slug|
      AidRule.find_or_create_by(slug: slug) do |r|
        r.active       = true
        r.name         = slug.humanize
        r.source_label = "test-fixture"
        # valid_from a une contrainte NOT NULL en DB. valid_until laissée
        # à 2030 pour que les checks de validité (valid_until >= today)
        # passent systématiquement dans les tests.
        r.valid_from   = Date.new(2024, 1, 1)
        r.valid_until  = Date.new(2030, 12, 31)
      end
    end
  end

  # ─── Helper ────────────────────────────────────────────────────────

  # Construit une Property paramétrable sans toucher à la DB.
  # Les defaults correspondent à un cas "modeste F→C en Grand Nancy" qui
  # déclenche MPR Ampleur (saut de 3 classes, income modeste).
  def build_property(attrs = {})
    defaults = {
      address: "1 rue du Test",
      city: "Nancy",
      zipcode: "54000",
      surface: 100.0,
      dpe_class: "F",
      dpe_target: "C",
      income_bracket: "modeste",
      property_type: "maison",
      construction_year: 1970,
      description: "",
      equipements_selection: {},
      travaux_selection: {}
    }
    Property.new(defaults.merge(attrs))
  end

  # ─── Rétrocompatibilité ────────────────────────────────────────────

  test "call sans paramètre travaux_actifs a la structure attendue" do
    r = AidCalculatorService.new(build_property).call

    assert_kind_of Hash, r
    %i[subventions aides_potentielles financement total_subventions errors calculated_at].each do |key|
      assert r.key?(key), "Clé manquante dans le résultat : #{key}"
    end
    assert_kind_of Array, r[:subventions]
    assert_kind_of Array, r[:errors]
    assert_kind_of Numeric, r[:total_subventions]
  end

  test "call avec travaux_actifs: nil donne le même résultat que sans paramètre" do
    p = build_property
    p.pac_air_eau = true

    r1 = AidCalculatorService.new(p).call
    r2 = AidCalculatorService.new(p, travaux_actifs: nil).call

    assert_equal r1[:total_subventions], r2[:total_subventions],
                 "nil explicite et absence de paramètre doivent être équivalents"
  end

  # ─── Filtre par travaux_actifs ────────────────────────────────────

  # On se place en MPR Par geste (saut 1 → pas Ampleur) pour que le filtre
  # ait un effet direct et mesurable sur les forfaits équipement.
  test "filtre [] donne un total strictement inférieur à sans filtre" do
    p = build_property(income_bracket: "intermediaire", dpe_target: "E")
    p.pac_air_eau       = true
    p.nb_parois_vitrees = 10

    r_sans = AidCalculatorService.new(p).call
    r_vide = AidCalculatorService.new(p, travaux_actifs: []).call

    assert_operator r_vide[:total_subventions], :<, r_sans[:total_subventions],
                    "filtre [] (#{r_vide[:total_subventions]} €) devrait être < sans filtre (#{r_sans[:total_subventions]} €)"
  end

  test "filtre ['chauffage'] inclut pac_air_eau mais exclut nb_parois_vitrees" do
    p = build_property(income_bracket: "intermediaire", dpe_target: "E")
    p.pac_air_eau       = true
    p.nb_parois_vitrees = 10

    r_sans      = AidCalculatorService.new(p).call
    r_chauffage = AidCalculatorService.new(p, travaux_actifs: ["chauffage"]).call
    r_vide      = AidCalculatorService.new(p, travaux_actifs: []).call

    assert_operator r_chauffage[:total_subventions], :<, r_sans[:total_subventions]
    assert_operator r_chauffage[:total_subventions], :>, r_vide[:total_subventions]
  end

  test "filtre ['menuiseries'] inclut nb_parois_vitrees mais exclut pac_air_eau" do
    p = build_property(income_bracket: "intermediaire", dpe_target: "E")
    p.pac_air_eau       = true
    p.nb_parois_vitrees = 10

    r_menuis = AidCalculatorService.new(p, travaux_actifs: ["menuiseries"]).call

    # Le seul équipement actif doit être nb_parois_vitrees (10 fenêtres).
    # Le total devrait être > 0 et < sans filtre.
    r_sans   = AidCalculatorService.new(p).call
    assert_operator r_menuis[:total_subventions], :<, r_sans[:total_subventions]
    assert_operator r_menuis[:total_subventions], :>, 0
  end

  test "audit_energetique reste pris en compte même avec filtre []" do
    # audit_energetique est dans ALWAYS_ON_EQUIPEMENTS : c'est un acte
    # d'accompagnement, pas un travail de rénovation. Il doit rester actif
    # quels que soient les macros cochés.
    p = build_property(income_bracket: "intermediaire", dpe_target: "E")
    p.audit_energetique = true

    r_vide = AidCalculatorService.new(p, travaux_actifs: []).call

    # Forfait audit en intermediaire : 300 € (voir MPR_PAR_GESTE_FORFAITS).
    # Avec uniquement audit actif, total_subventions doit être > 0.
    assert_operator r_vide[:total_subventions], :>, 0,
                    "audit_energetique devrait rester actif même filtre []"
  end

  # ─── Erreurs métier ───────────────────────────────────────────────

  test "erreur si income_bracket manquant" do
    p = build_property(income_bracket: nil)
    r = AidCalculatorService.new(p).call

    assert r[:errors].any? { |e| e.include?("Revenus non renseignés") },
           "Erreur sur revenus manquants attendue, reçu : #{r[:errors].inspect}"
  end

  test "erreur si logement < 15 ans" do
    p = build_property(construction_year: Date.current.year - 5)
    r = AidCalculatorService.new(p).call

    assert r[:errors].any? { |e| e.include?("≥ 15 ans") },
           "Erreur sur ancienneté attendue, reçu : #{r[:errors].inspect}"
  end

  test "bien avec équipement déclenche un calcul d'aide > 0" do
    # Un bien "éligible" au sens métier a forcément au moins un équipement
    # ou une surface détectée par l'analyse Claude. Sans rien, le service
    # retourne correctement 0 avec une erreur "Aucun travail détaillé détecté" :
    # c'est le comportement attendu, pas un bug.
    p = build_property
    p.pac_air_eau = true

    r = AidCalculatorService.new(p).call

    assert_operator r[:total_subventions], :>, 0,
                    "total=#{r[:total_subventions]}, subv=#{r[:subventions].inspect}, errors=#{r[:errors].inspect}"
  end

  # ─── Override LECTURE SEULE de dpe_target ────────────────────────────

  # L'override sert à la projection ("à la cible B, ça donnerait X €")
  # sans toucher à la cible serveur. Le garde-fou critique : la Property
  # ne doit JAMAIS être mutée — c'est ce qui a fait régresser hier (bug
  # auto-snap où la cible sautait à B toute seule).
  test "dpe_target_override ne mute pas la Property" do
    p = build_property(dpe_target: "C")
    p.pac_air_eau = true

    snapshot = p.changes.deep_dup

    AidCalculatorService.new(p, dpe_target_override: "B").call

    assert_equal "C", p.dpe_target, "dpe_target doit rester 'C' après un appel override"
    assert_equal snapshot["dpe_target"], p.changes["dpe_target"],
                 "L'override ne doit pas modifier l'état dirty de dpe_target (sinon save() ultérieur persisterait B). " \
                 "Avant : #{snapshot["dpe_target"].inspect}, après : #{p.changes["dpe_target"].inspect}"
  end

  test "dpe_target_override produit un calcul différent de la cible serveur" do
    # F → C : saut 3 (parcours accompagné OK). F → B : saut 4.
    # Le plafond HT MPR Ampleur saute de 40 000 € à 40 000 € (idem),
    # mais Grand Nancy Réno Globale qui n'est qu'en potentielle à C
    # bascule en subvention à B → total différent.
    p = build_property(dpe_class: "F", dpe_target: "C", city: "Nancy", income_bracket: "modeste")
    p.code_insee        = "54395"
    p.surface_ite       = 80
    p.surface_iti       = 30
    p.vmc_double_flux   = true

    r_courant = AidCalculatorService.new(p).call
    r_projete = AidCalculatorService.new(p, dpe_target_override: "B").call

    assert_operator r_projete[:total_subventions], :>, r_courant[:total_subventions],
                    "Override 'B' devrait débloquer Grand Nancy Réno Globale et donc augmenter le total " \
                    "(courant=#{r_courant[:total_subventions]} €, projeté=#{r_projete[:total_subventions]} €)"
  end

  # ─── Éco-PTZ ───────────────────────────────────────────────────────

  test "eco_ptz retourné comme financement, pas comme subvention" do
    p = build_property
    p.pac_air_eau = true
    r = AidCalculatorService.new(p).call

    ptz = r[:financement].find { |f| f[:type] == "eco_ptz" }
    assert ptz, "Éco-PTZ attendu dans :financement, reçu : financement=#{r[:financement].inspect}, errors=#{r[:errors].inspect}"
    assert_equal :pret, ptz[:nature]

    # Ne doit pas figurer dans :subventions
    in_subv = r[:subventions].find { |s| s[:type] == "eco_ptz" }
    assert_nil in_subv, "Éco-PTZ ne doit pas figurer dans :subventions"
  end
end
