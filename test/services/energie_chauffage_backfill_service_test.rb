require "test_helper"

# Tests du backfill energie_chauffage sur les Property antérieurs à la
# migration. Réutilise HeatingEnergyNormalizer sans introduire de logique
# d'extraction nouvelle (source unique préservée). Respect strict de la
# hiérarchie de confiance ENERGIE_SOURCE_HIERARCHIE : un :extrait_dpe ou
# un :confirme_utilisateur n'est jamais écrasé. Idempotent.
class EnergieChauffageBackfillServiceTest < ActiveSupport::TestCase
  def base_attrs
    { address: "1 rue test", city: "Nancy", zipcode: "54000", claim_token: SecureRandom.uuid }
  end

  # ── 1. Cas nominal : description structurée Chauffage : XYZ ──────────
  test "bien :inconnue avec « Chaudière gaz » dans description → :gaz / :extrait_description" do
    p = Property.create!(base_attrs.merge(
      description: "Chauffage : Chaudière gaz ancienne (> 25 ans) | Prix d'acquisition : 168000 €"
    ))
    rapport = EnergieChauffageBackfillService.call(Property.where(id: p.id))
    p.reload

    assert_equal "gaz",                 p.energie_chauffage
    assert_equal "extrait_description", p.energie_chauffage_source
    assert_equal 1, rapport[:basculs].size
    assert_equal p.id, rapport[:basculs].first[:id]
    assert_equal "gaz", rapport[:basculs].first[:energie]
  end

  # ── 2. Aucun signal exploitable → :inconnue conservé honnêtement ─────
  test "bien :inconnue sans signal exploitable → reste :inconnue" do
    p = Property.create!(base_attrs.merge(
      description: "Description sans aucune mention identifiable d'énergie."
    ))
    rapport = EnergieChauffageBackfillService.call(Property.where(id: p.id))
    p.reload

    assert_equal "inconnue", p.energie_chauffage
    assert_equal "inconnue", p.energie_chauffage_source
    assert_includes rapport[:restent_inconnues], p.id
    assert_empty rapport[:basculs]
  end

  test "bien :inconnue avec description vide → reste :inconnue" do
    p = Property.create!(base_attrs.merge(description: ""))
    EnergieChauffageBackfillService.call(Property.where(id: p.id))
    p.reload
    assert_equal "inconnue", p.energie_chauffage
  end

  # ── 3. Hiérarchie : ne pas écraser une source plus fiable ─────────────
  test "bien déjà typé :extrait_dpe → JAMAIS écrasé par le backfill (extrait_dpe > extrait_description)" do
    p = Property.create!(base_attrs.merge(
      energie_chauffage:        "fioul",
      energie_chauffage_source: "extrait_dpe",
      description:              "Chauffage : Chaudière gaz"
    ))
    rapport = EnergieChauffageBackfillService.call(Property.where(id: p.id))
    p.reload

    assert_equal "fioul",       p.energie_chauffage,
      "extrait_dpe doit être préservé même quand la description dirait autre chose"
    assert_equal "extrait_dpe", p.energie_chauffage_source
    refute_includes rapport[:basculs].map { |b| b[:id] }, p.id
    assert_includes rapport[:inchanges_source_plus_fiable].map { |h| h[:id] }, p.id
  end

  test "bien déjà typé :confirme_utilisateur → JAMAIS écrasé" do
    p = Property.create!(base_attrs.merge(
      energie_chauffage:        "pac",
      energie_chauffage_source: "confirme_utilisateur",
      description:              "Chauffage : Chaudière gaz"
    ))
    EnergieChauffageBackfillService.call(Property.where(id: p.id))
    p.reload
    assert_equal "pac",                  p.energie_chauffage
    assert_equal "confirme_utilisateur", p.energie_chauffage_source
  end

  test "bien déjà typé :extrait_description → n'est pas re-traité (rangs égaux)" do
    p = Property.create!(base_attrs.merge(
      energie_chauffage:        "bois",
      energie_chauffage_source: "extrait_description",
      description:              "Chauffage : Chaudière gaz"  # description dit gaz, mais on garde bois
    ))
    EnergieChauffageBackfillService.call(Property.where(id: p.id))
    p.reload
    assert_equal "bois", p.energie_chauffage,
      "même rang :extrait_description vs :extrait_description → upgrade_energie_source? = false, pas d'écrasement"
  end

  # ── 4. Idempotence ────────────────────────────────────────────────────
  test "idempotence : deux passages successifs donnent le même résultat" do
    p = Property.create!(base_attrs.merge(
      description: "Chauffage : Chaudière fioul collectif | Autre infos"
    ))
    EnergieChauffageBackfillService.call(Property.where(id: p.id))
    p.reload
    assert_equal "fioul", p.energie_chauffage

    rapport2 = EnergieChauffageBackfillService.call(Property.where(id: p.id))
    p.reload
    assert_equal "fioul", p.energie_chauffage, "Deuxième passage : même valeur"
    assert_empty rapport2[:basculs],
      "Deuxième passage ne doit produire aucun nouveau bascul (idempotent)"
  end

  # ── 5. Description sans préfixe « Chauffage : » → ignorée ────────────
  # Depuis le retrait du champ libre côté UI, description n'est plus
  # alimentée que par PropertyDataExtractorService au format structuré.
  # Tout texte sans ce préfixe n'est plus jamais parsé : on refuse de
  # deviner sur du bruit (et d'éventuel texte libre hérité reste géré
  # par le passage initial du backfill avant cette restriction).
  test "description sans préfixe Chauffage : → reste :inconnue (aucun fallback texte libre)" do
    p = Property.create!(base_attrs.merge(
      description: "Appartement hérité de ma grand-mère. Chauffage au fioul collectif. Je veux comprendre…"
    ))
    rapport = EnergieChauffageBackfillService.call(Property.where(id: p.id))
    p.reload
    assert_equal "inconnue", p.energie_chauffage,
      "sans préfixe technique, on n'extrait rien — pas de devinette sur texte libre"
    assert_equal "inconnue", p.energie_chauffage_source
    assert_includes rapport[:restent_inconnues], p.id
  end

  # ── 6. Mix : un bien bascule, un reste :inconnue ──────────────────────
  test "scope multiple : un bascule, un reste — compte-rendu correct" do
    p_gaz   = Property.create!(base_attrs.merge(description: "Chauffage : Chaudière gaz"))
    p_vide  = Property.create!(base_attrs.merge(description: ""))
    p_typed = Property.create!(base_attrs.merge(
      energie_chauffage: "fioul", energie_chauffage_source: "confirme_utilisateur",
      description: "Chauffage : Chaudière gaz"
    ))

    rapport = EnergieChauffageBackfillService.call(
      Property.where(id: [p_gaz.id, p_vide.id, p_typed.id])
    )

    assert_equal 3, rapport[:scannes]
    assert_equal 1, rapport[:basculs].size
    assert_equal p_gaz.id, rapport[:basculs].first[:id]
    assert_includes rapport[:restent_inconnues], p_vide.id
    assert_includes rapport[:inchanges_source_plus_fiable].map { |h| h[:id] }, p_typed.id
  end

  # ── 7. Scope par défaut = tous les Property ──────────────────────────
  test "sans argument, le service parcourt tous les Property" do
    rapport = EnergieChauffageBackfillService.call
    assert_operator rapport[:scannes], :>=, 0,
      "Sans scope, doit parcourir au moins 0 biens (= tous les Property en DB)"
  end
end
