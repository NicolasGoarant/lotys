require "test_helper"

# Capture structurée de l'énergie de chauffage par PropertyDataExtractorService.
# On teste UNIQUEMENT la méthode privée update_property — pas l'appel Claude.
# Le champ heating_system du JSON Claude (déjà parsé en l. 148 du service)
# alimente Property#energie_chauffage en parallèle de la description texte libre.
class PropertyDataExtractorServiceTest < ActiveSupport::TestCase
  def fresh_property
    Property.create!(
      address: "1 rue de test",
      city:    "Nancy",
      zipcode: "54000",
      surface: 100,
      construction_year: 1970,
      claim_token: SecureRandom.hex(16)
    )
  end

  def apply(property, data)
    PropertyDataExtractorService.new(property).send(:update_property, data)
  end

  # ── Capture nominale ────────────────────────────────────────────────────
  test "« Chaudière gaz ancienne » → energie_chauffage=:gaz / source=:extrait_description" do
    p = fresh_property
    apply(p, { "heating_system" => "Chaudière gaz ancienne (> 25 ans)" })
    p.reload
    assert_equal "gaz",                 p.energie_chauffage
    assert_equal "extrait_description", p.energie_chauffage_source
  end

  test "« Radiateurs électriques » → :electricite / :extrait_description" do
    p = fresh_property
    apply(p, { "heating_system" => "Radiateurs électriques à inertie" })
    p.reload
    assert_equal "electricite",         p.energie_chauffage
    assert_equal "extrait_description", p.energie_chauffage_source
  end

  # ── Non-régression : description texte libre EN PLUS du champ typé ─────
  test "la description texte libre existante reste alimentée (non-régression)" do
    p = fresh_property
    apply(p, {
      "heating_system"   => "Chaudière gaz ancienne",
      "wall_insulation"  => "non isolés (parpaing brut)",
      "roof_insulation"  => "combles non isolés"
    })
    p.reload
    assert_match(/Chauffage : Chaudière gaz ancienne/, p.description)
    assert_match(/Isolation murs : non isolés/,        p.description)
    assert_match(/Isolation toiture : combles/,         p.description)
    # ET le champ structuré est posé en parallèle
    assert_equal "gaz", p.energie_chauffage
  end

  # ── Cas dégradés ────────────────────────────────────────────────────────
  test "heating_system non reconnu (« Panneau solaire ») → energie reste :inconnue" do
    p = fresh_property
    apply(p, { "heating_system" => "Panneau solaire d'appoint" })
    p.reload
    assert_equal "inconnue", p.energie_chauffage,
      "On ne dégrade pas un :inconnue par un :inconnue / :extrait_description vide"
    assert_equal "inconnue", p.energie_chauffage_source
  end

  test "heating_system absent → energie reste :inconnue (pas de NoMethodError)" do
    p = fresh_property
    apply(p, { "surface" => 100 })
    p.reload
    assert_equal "inconnue", p.energie_chauffage
    assert_equal "inconnue", p.energie_chauffage_source
  end

  # ── Priorité des sources ────────────────────────────────────────────────
  test "n'écrase PAS un :extrait_dpe déjà posé (extrait_dpe > extrait_description)" do
    p = fresh_property
    p.update!(energie_chauffage: "fioul", energie_chauffage_source: "extrait_dpe")
    apply(p, { "heating_system" => "Chaudière gaz" })
    p.reload
    assert_equal "fioul",       p.energie_chauffage,
      "extrait_dpe est plus autoritaire — il NE doit PAS être écrasé"
    assert_equal "extrait_dpe", p.energie_chauffage_source
  end

  test "écrase un :deduit (extrait_description > deduit)" do
    p = fresh_property
    p.update!(energie_chauffage: "fioul", energie_chauffage_source: "deduit")
    apply(p, { "heating_system" => "Chaudière gaz" })
    p.reload
    assert_equal "gaz",                 p.energie_chauffage,
      "Une extraction réelle doit pouvoir corriger un proxy déduit"
    assert_equal "extrait_description", p.energie_chauffage_source
  end
end
