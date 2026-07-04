require "test_helper"

# Tests du filet déterministe de récupération de l'année de construction.
#
# Deux familles de tests, comme SurfaceRegexFallback :
#   1. POSITIFS : le filet retrouve bien "1928" sur chacun des libellés
#      canoniques (DPE, titre de propriété, prose "construit en").
#   2. NÉGATIFS : le filet ne se laisse PAS piéger par des années
#      parasites (facture, acte notarié, AG copro, millésime de loi).
#
# Les négatifs sont la garantie de sûreté : un mauvais chiffre fausse
# la matrice DPE et supprime le bandeau d'invite qui devrait s'afficher.
class ConstructionYearRegexFallbackTest < ActiveSupport::TestCase
  # ─── 1. POSITIFS ─────────────────────────────────────────────────────

  test "specimen DPE : « Année de construction : 1928 » renvoie 1928" do
    text = <<~TXT
      Adresse : 12 rue du Haut-Rivage, 54220 Malzéville
      Type : Maison individuelle
      Surface habitable : 118 m²
      Année de construction : 1928
      Consommation énergie primaire : 410 kWh/m².an
    TXT
    assert_equal 1928, ConstructionYearRegexFallback.call(text)
  end

  test "specimen titre de propriété : « Date de construction : 1928 » renvoie 1928" do
    text = <<~TXT
      Titre de propriété — 12 rue du Haut-Rivage, Malzéville.
      Surface habitable Loi Carrez/Boutin : 118 m².
      Date de construction : 1928.
    TXT
    assert_equal 1928, ConstructionYearRegexFallback.call(text)
  end

  test "specimen prose : « construit en 1928 » renvoie 1928" do
    text = "Bâtiment construit en 1928, réhabilité en 1985."
    assert_equal 1928, ConstructionYearRegexFallback.call(text)
  end

  test "tolère l'accent : « Annee de construction » (sans é) renvoie 1928" do
    text = "Annee de construction : 1928"
    assert_equal 1928, ConstructionYearRegexFallback.call(text)
  end

  test "tolère « construite en » (accord féminin) — renvoie 1928" do
    text = "Maison construite en 1928 par l'architecte X."
    assert_equal 1928, ConstructionYearRegexFallback.call(text)
  end

  # ── Cas prod (bug Malzéville) : pdf-reader restitue la valeur DPE
  # tabulaire sur une ligne séparée, parfois avec une ligne vide entre
  # le libellé et la valeur. La regex doit rester tolérante à ce split
  # (fenêtre bornée pour éviter de capturer une année trois § plus loin).
  test "spécimen DPE tabulaire : libellé, ligne vide, valeur → renvoie 1928" do
    text = <<~TXT
      Adresse : 12 rue du Haut-Rivage
      Type : Maison individuelle
      Année de construction :

      1928
      Consommation énergie primaire : 410 kWh/m².an
    TXT
    assert_equal 1928, ConstructionYearRegexFallback.call(text)
  end

  test "spécimen DPE tabulaire : libellé et valeur sur lignes adjacentes → renvoie 1928" do
    text = <<~TXT
      Année de construction :
      1928
    TXT
    assert_equal 1928, ConstructionYearRegexFallback.call(text)
  end

  test "spécimen DPE colonnes : libellé + espaces d'alignement + valeur → renvoie 1928" do
    text = "Année de construction                    1928\nZone géographique : H1"
    assert_equal 1928, ConstructionYearRegexFallback.call(text)
  end

  test "matches multiples sur les 3 docs concaténés convergent vers 1928" do
    text = <<~TXT
      === Titre de propriété ===
      Date de construction : 1928.

      === Dpe ===
      Année de construction : 1928
      Consommation énergie primaire : 410 kWh/m².an

      === Facture ===
      Point de livraison : GI000000123456
      Période facturée : du 16 décembre 2025 au 15 mars 2026 (90 jours)
    TXT
    assert_equal 1928, ConstructionYearRegexFallback.call(text)
  end

  # ─── 2. NÉGATIFS — la garantie de sûreté ─────────────────────────────

  test "ne capture PAS 2019 dans « acte notarié du 12 mars 2019 »" do
    text = "Acte notarié reçu le 12 mars 2019 par Me Dupont."
    assert_nil ConstructionYearRegexFallback.call(text)
  end

  test "ne capture PAS 2026 dans « Période facturée : … 2026 »" do
    text = "Période facturée : du 16 décembre 2025 au 15 mars 2026 (90 jours)."
    assert_nil ConstructionYearRegexFallback.call(text)
  end

  test "ne capture PAS 2024 dans « Assemblée générale du 12 septembre 2024 »" do
    text = "Document de copropriété : assemblée générale du 12 septembre 2024."
    assert_nil ConstructionYearRegexFallback.call(text)
  end

  test "ne capture PAS 1996 dans « Loi Carrez 1996 » (millésime de loi)" do
    text = "Surface certifiée conformément à la Loi Carrez 1996."
    assert_nil ConstructionYearRegexFallback.call(text)
  end

  test "ne capture PAS 1985 dans « réhabilité en 1985 » sans contexte construction" do
    text = "Immeuble réhabilité en 1985."
    assert_nil ConstructionYearRegexFallback.call(text,)
  end

  test "« Année de construction : NC » puis facture 2026 en fin de section → nil" do
    # Bornage à 20 chars non-digit ET non-\n : la facture d'après ne
    # doit pas être aspirée dans le match.
    text = <<~TXT
      Année de construction : NC (non communiquée)

      Facture émise le 15 mars 2026
    TXT
    assert_nil ConstructionYearRegexFallback.call(text)
  end

  # ─── 3. DÉSACCORD : le filet refuse de deviner ───────────────────────

  test "désaccord entre docs (1928 vs 1962, écart > 2) → nil" do
    text = <<~TXT
      Titre de propriété — Date de construction : 1928.
      DPE — Année de construction : 1962.
    TXT
    assert_nil ConstructionYearRegexFallback.call(text)
  end

  test "accord à 1 an près (1928 vs 1927) → retient le plus fréquent" do
    text = <<~TXT
      Année de construction : 1928
      Année de construction : 1928
      Date de construction : 1927
    TXT
    assert_equal 1928, ConstructionYearRegexFallback.call(text)
  end

  # ─── 4. BORNES ───────────────────────────────────────────────────────

  test "rejette une année aberrante avant 1700" do
    text = "Année de construction : 1500"
    assert_nil ConstructionYearRegexFallback.call(text)
  end

  test "rejette une année clairement future (> annnée courante + 2)" do
    future = Date.current.year + 5
    text   = "Année de construction : #{future}"
    assert_nil ConstructionYearRegexFallback.call(text)
  end

  test "accepte une VEFA à livrer (année courante + 2)" do
    year = Date.current.year + 2
    text = "Année de construction : #{year}"
    assert_equal year, ConstructionYearRegexFallback.call(text)
  end

  # ─── 5. ENTRÉES DÉGÉNÉRÉES ──────────────────────────────────────────

  test "texte vide → nil" do
    assert_nil ConstructionYearRegexFallback.call("")
  end

  test "nil en entrée → nil" do
    assert_nil ConstructionYearRegexFallback.call(nil)
  end

  test "texte sans aucune mention de date de construction → nil" do
    text = "Diagnostic amiante — sans repérage suspect. Surface : 95 m²."
    assert_nil ConstructionYearRegexFallback.call(text)
  end
end
