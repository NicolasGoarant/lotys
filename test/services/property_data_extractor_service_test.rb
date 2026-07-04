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

  # ────────────────────────────────────────────────────────────────────
  # C3 — Adresse détectée : dépose dans les colonnes _detected uniquement
  # ────────────────────────────────────────────────────────────────────

  # Property sans adresse (parcours "documents seuls" — C2).
  # save(validate: false) crée la ligne, puis on rattache un Document :
  # fidèle au parcours réel où PropertyAnalysisJob tourne APRÈS que le
  # controller ait attaché un doc. Sans ce doc, l'update en fin de
  # update_property échouerait à la validation address_or_documents_provided.
  def property_sans_adresse
    p = Property.new(claim_token: SecureRandom.hex(16))
    p.save(validate: false)
    p.documents.create!(document_type: :dpe, name: "fixture-dpe.pdf")
    p
  end

  test "adresse DPE + tous champs valides → posée dans _detected (source dpe)" do
    p = property_sans_adresse
    apply(p, {
      "address"        => "12 rue du Haut-Rivage",
      "city"           => "Malzéville",
      "zipcode"        => "54220",
      "address_source" => "dpe"
    })
    p.reload

    assert_equal "12 rue du Haut-Rivage", p.address_detected
    assert_equal "Malzéville",             p.city_detected
    assert_equal "54220",                  p.zipcode_detected
    assert_equal "dpe",                    p.address_source

    # Verrou critique : les colonnes de vérité ne bougent PAS.
    assert_nil p.address, "address (colonne de vérité) doit rester NULL avant confirmation"
    assert_nil p.city
    assert_nil p.zipcode
    assert_nil p.address_confirmed_at, "confirmation reste NULL — c'est le clic user qui la pose (C5)"
  end

  test "hiérarchie : source titre_propriete acceptée" do
    p = property_sans_adresse
    apply(p, {
      "address"        => "17 rue du Général Leclerc",
      "city"           => "Nancy",
      "zipcode"        => "54000",
      "address_source" => "titre_propriete"
    })
    p.reload
    assert_equal "titre_propriete", p.address_source
    assert_equal "17 rue du Général Leclerc", p.address_detected
  end

  test "hiérarchie : source facture acceptée (lieu de consommation)" do
    p = property_sans_adresse
    apply(p, {
      "address"        => "5 impasse des Vignes",
      "city"           => "Vandœuvre-lès-Nancy",
      "zipcode"        => "54500",
      "address_source" => "facture"
    })
    p.reload
    assert_equal "facture", p.address_source
  end

  test "adresse déjà saisie par l'utilisateur → LLM n'écrase PAS" do
    p = Property.create!(
      address:  "1 rue Existante",
      city:     "Nancy",
      zipcode:  "54000",
      claim_token: SecureRandom.hex(16)
    )
    apply(p, {
      "address"        => "999 rue Détectée",
      "city"           => "Autre Ville",
      "zipcode"        => "75001",
      "address_source" => "dpe"
    })
    p.reload

    # address de vérité intacte
    assert_equal "1 rue Existante", p.address
    # Colonnes _detected NON remplies non plus — pas besoin de bandeau
    # de confirmation si l'utilisateur a saisi lui-même.
    assert_nil p.address_detected, "Pas de détection déposée si address déjà saisie"
    assert_nil p.address_source
  end

  test "address_source inventé par le LLM (hors liste) → rejeté" do
    p = property_sans_adresse
    apply(p, {
      "address"        => "12 rue X",
      "city"           => "Nancy",
      "zipcode"        => "54000",
      "address_source" => "cadastre"       # hors liste blanche
    })
    p.reload
    assert_nil p.address_detected, "Source inconnue → aucune détection déposée"
    assert_nil p.address_source
  end

  test "address_source = null explicite (LLM ne sait pas trancher) → rien déposé" do
    p = property_sans_adresse
    apply(p, {
      "address"        => "12 rue X",
      "city"           => "Nancy",
      "zipcode"        => "54000",
      "address_source" => nil
    })
    p.reload
    assert_nil p.address_detected
  end

  test "zipcode malformé → rejet complet du bloc adresse" do
    p = property_sans_adresse
    apply(p, {
      "address"        => "12 rue X",
      "city"           => "Nancy",
      "zipcode"        => "5400",  # 4 chiffres — invalide
      "address_source" => "dpe"
    })
    p.reload
    assert_nil p.address_detected, "Zipcode malformé → rien n'est déposé"
    assert_nil p.zipcode_detected
    assert_nil p.address_source
  end

  test "champ manquant (city null) → rejet complet du bloc adresse" do
    p = property_sans_adresse
    apply(p, {
      "address"        => "12 rue X",
      "city"           => nil,
      "zipcode"        => "54000",
      "address_source" => "dpe"
    })
    p.reload
    assert_nil p.address_detected, "Trio incomplet → rien n'est déposé (atomique)"
  end
end
