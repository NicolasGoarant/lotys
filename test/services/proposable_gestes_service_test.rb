require "test_helper"

# Tests de ProposableGestesService — la liste des gestes ACTIONNABLES
# pour un bien donné, dérivée des FAITS et non de la narration LLM.
#
# Contexte : bug biens 232/233 (diag 07/07). Deux runs LLM sur le même
# PDF proposaient deux listes de gestes différentes ; ce service rend
# la liste indépendante du LLM en la dérivant des colonnes serveur.
class ProposableGestesServiceTest < ActiveSupport::TestCase
  def base_attrs
    {
      address:     "1 rue de test",
      city:        "Nancy",
      zipcode:     "54000",
      surface:     72,
      construction_year: 1965,
      claim_token: SecureRandom.uuid
    }
  end

  # ─── Cas 1 : maison hors copropriété — TOUT est proposable ──────────
  test "maison hors copropriété : les 7 gestes sont proposables" do
    p = Property.new(base_attrs.merge(
      property_type:     "maison",
      is_copropriete:    false,
      energie_chauffage: "gaz"
    ))
    codes = ProposableGestesService.call(p)
    assert_equal TravauxMapperService::CANONICAL_CODES.sort, codes.sort,
      "Une maison hors copro ne devrait exclure aucun geste. Obtenu : #{codes.inspect}"
  end

  # ─── Cas 2 : copropriété gaz + aucun équipement individuel → chauffage exclu ──
  test "copro gaz collectif (aucun équipement individuel) : chauffage exclu" do
    p = Property.new(base_attrs.merge(
      property_type:     "appartement",
      is_copropriete:    true,
      energie_chauffage: "gaz",
      equipements_selection: {}
    ))
    codes = ProposableGestesService.call(p)
    refute_includes codes, "chauffage",
      "Le remplacement du chauffage ne peut pas être décidé seul en copro gaz collectif. " \
      "Obtenu : #{codes.inspect}"
  end

  # ─── Cas 3 : copro gaz + équipement individuel (PAC) → chauffage inclus ──
  test "copro gaz + PAC individuelle détectée : chauffage reste proposable" do
    p = Property.new(base_attrs.merge(
      property_type:     "appartement",
      is_copropriete:    true,
      energie_chauffage: "gaz",
      equipements_selection: { "pac_air_eau" => true }
    ))
    codes = ProposableGestesService.call(p)
    assert_includes codes, "chauffage",
      "Un lot en copro avec PAC individuelle a bien son propre système : le geste " \
      "chauffage doit rester proposable. Obtenu : #{codes.inspect}"
  end

  # ─── Cas 4 : copro électrique → chauffage inclus (convecteurs individuels) ──
  test "copro électrique : chauffage reste proposable (convecteurs individuels)" do
    p = Property.new(base_attrs.merge(
      property_type:     "appartement",
      is_copropriete:    true,
      energie_chauffage: "electricite"
    ))
    codes = ProposableGestesService.call(p)
    assert_includes codes, "chauffage",
      "En copro électrique le chauffage est individuel par convecteurs — " \
      "le geste doit rester proposable. Obtenu : #{codes.inspect}"
  end

  # ─── Cas 5 : maison gaz — chauffage inclus (pas de collectif possible) ──
  test "maison gaz : chauffage inclus (aucun collectif possible)" do
    p = Property.new(base_attrs.merge(
      property_type:     "maison",
      is_copropriete:    false,
      energie_chauffage: "gaz"
    ))
    codes = ProposableGestesService.call(p)
    assert_includes codes, "chauffage",
      "Une maison individuelle a toujours le chauffage proposable. Obtenu : #{codes.inspect}"
  end

  # ─── Cas 6 : appartement position_lot inconnue → conservateur (tout inclus) ──
  test "appartement position_lot inconnue : toiture et plancher restent proposables (conservateur)" do
    p = Property.new(base_attrs.merge(
      property_type:     "appartement",
      is_copropriete:    false,
      energie_chauffage: "electricite"
    ))
    # position_lot column absente au commit 1 : le service reçoit nil et
    # NE FILTRE PAS toiture / plancher bas. Comportement conservateur
    # documenté (on préfère un geste inutile à un geste manquant).
    codes = ProposableGestesService.call(p)
    assert_includes codes, "isolation_toiture",
      "position_lot inconnue → toiture doit rester proposable (conservateur). " \
      "Obtenu : #{codes.inspect}"
    assert_includes codes, "isolation_plancher_bas",
      "position_lot inconnue → plancher bas doit rester proposable (conservateur). " \
      "Obtenu : #{codes.inspect}"
  end

  # ─── Cas 7 : bien 232 (repro) — copro E gaz sans équipement individuel ──
  test "repro bien 232 : liste = {isolation_murs, isolation_toiture, isolation_plancher_bas, chauffe_eau, vmc, menuiseries}" do
    p = Property.new(base_attrs.merge(
      address:           "5 rue des Ombelles, Appt 12",
      city:              "Villers-lès-Nancy",
      zipcode:           "54600",
      surface:           72,
      construction_year: 1965,
      property_type:     "appartement",
      is_copropriete:    true,
      dpe_class:         "E",
      energie_chauffage: "gaz",
      equipements_selection: {} # aucun équipement de chauffage individuel
    ))
    codes = ProposableGestesService.call(p)
    # Chauffage exclu par la règle copro gaz collectif ; toiture/plancher
    # restent inclus (position_lot inconnue au commit 1).
    refute_includes codes, "chauffage",
      "Bien 232 : chauffage doit être exclu. Obtenu : #{codes.inspect}"
    # Les 6 autres restent en attendant que le commit 2 introduise
    # position_lot et que le commit 3 branche l'exclusion physique.
    assert_equal (TravauxMapperService::CANONICAL_CODES - ["chauffage"]).sort,
                 codes.sort,
      "Bien 232 (position_lot inconnue) : tous les gestes sauf chauffage. " \
      "Obtenu : #{codes.inspect}"
  end
end
