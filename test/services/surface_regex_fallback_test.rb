require "test_helper"

# Tests du filet déterministe de récupération de la surface habitable.
#
# Deux familles de tests, l'ordre est volontaire :
#   1. POSITIFS : le filet retrouve bien "95" sur chacun des 3 specimens.
#   2. NÉGATIFS : le filet ne se laisse PAS piéger par des "m²" parasites
#      (kWh/m², R thermique, surface travaux, comparable générique).
#
# Les négatifs sont la garantie de sûreté : sans eux, le filet remplacerait
# le bandeau "analyse incomplète" par un mauvais chiffre — pire que rien.
class SurfaceRegexFallbackTest < ActiveSupport::TestCase
  # ─── 1. POSITIFS ─────────────────────────────────────────────────────

  test "specimen titre de propriété : Surface habitable Loi Carrez/Boutin renvoie 95" do
    text = <<~TXT
      Surface habitable Loi Carrez/Boutin : 95 m² (quatre-vingt-quinze mètres carrés).
      Année de construction déclarée : 1962.
    TXT
    assert_equal 95, SurfaceRegexFallback.call(text)
  end

  test "specimen DPE : libellé Surface habitable renvoie 95" do
    text = <<~TXT
      Adresse : 14 rue des Tilleuls, 54500 Vandœuvre-lès-Nancy
      Type : Maison individuelle
      Surface habitable : 95 m²
      Année de construction : 1962
      Consommation énergie primaire : 410 kWh/m².an
    TXT
    assert_equal 95, SurfaceRegexFallback.call(text)
  end

  test "specimen facture énergie : Type de logement — 95 m² renvoie 95" do
    text = <<~TXT
      Point de livraison (PCE) : GI000000123456
      Adresse de consommation : 14 rue des Tilleuls, 54500 Vandœuvre-lès-Nancy
      Type de logement : Maison individuelle — 95 m²
      Période facturée : du 16 décembre 2025 au 15 mars 2026 (90 jours)
    TXT
    assert_equal 95, SurfaceRegexFallback.call(text)
  end

  test "matches multiples sur les 3 docs concaténés convergent vers 95" do
    text = <<~TXT
      === Titre de propriété ===
      Surface habitable Loi Carrez/Boutin : 95 m² (quatre-vingt-quinze mètres carrés).

      === Dpe ===
      Surface habitable : 95 m²
      Consommation énergie primaire : 410 kWh/m².an

      === Facture ===
      Type de logement : Maison individuelle — 95 m²
    TXT
    assert_equal 95, SurfaceRegexFallback.call(text)
  end

  test "tolère m2 (sans exposant) à la place de m²" do
    text = "Surface habitable : 95 m2"
    assert_equal 95, SurfaceRegexFallback.call(text)
  end

  test "tolère l'absence d'espace entre nombre et unité" do
    text = "Surface habitable : 95m²"
    assert_equal 95, SurfaceRegexFallback.call(text)
  end

  # ── Multi-lignes : mise en page tabulaire des DPE ────────────────────
  # Même avec `pdftotext -layout`, certains DPE restituent le libellé et
  # la valeur sur des lignes différentes quand le PDF d'origine utilise
  # une mise en page en colonnes. Même famille de cas que
  # ConstructionYearRegexFallback.

  test "spécimen DPE tabulaire : libellé, ligne vide, valeur → renvoie 95" do
    text = <<~TXT
      Adresse : 14 rue des Tilleuls, 54500 Vandœuvre
      Surface habitable :

      95 m²
      Année de construction : 1962
    TXT
    assert_equal 95, SurfaceRegexFallback.call(text)
  end

  test "spécimen DPE tabulaire : libellé et valeur sur lignes adjacentes → renvoie 95" do
    text = <<~TXT
      Surface habitable :
      95 m²
    TXT
    assert_equal 95, SurfaceRegexFallback.call(text)
  end

  # ─── 2. NÉGATIFS — la garantie de sûreté ─────────────────────────────

  test "ne capture PAS 410 dans 410 kWh/m².an" do
    text = "Consommation énergie primaire : 410 kWh/m².an"
    assert_nil SurfaceRegexFallback.call(text)
  end

  test "ne capture PAS 7 dans R ≥ 7 m².K/W" do
    text = "Isolation des combles perdus (R ≥ 7 m².K/W) recommandée."
    assert_nil SurfaceRegexFallback.call(text)
  end

  test "ne capture PAS 120 dans 120 m² de toiture à isoler" do
    text = "Travaux à prévoir : 120 m² de toiture à isoler en sarking."
    assert_nil SurfaceRegexFallback.call(text)
  end

  test "ne capture PAS 100 dans une maison de 100 m² en moyenne (comparable générique)" do
    text = "À titre indicatif, une maison de 100 m² en moyenne consomme 15 000 kWh par an."
    assert_nil SurfaceRegexFallback.call(text)
  end

  test "ne capture PAS 83 dans 83 kg CO₂eq/m².an (GES du DPE)" do
    text = "Émissions GES : 83 kg CO₂eq/m².an"
    assert_nil SurfaceRegexFallback.call(text)
  end

  test "ne capture PAS sous Type de travaux : … — 120 m² (faux ami du pattern type_logement)" do
    text = "Type de travaux : isolation murs par l'extérieur — 120 m² à traiter"
    assert_nil SurfaceRegexFallback.call(text)
  end

  # ─── 3. DÉSACCORD : le filet refuse de deviner ───────────────────────

  test "désaccord entre docs (95 vs 92, écart > 2) → nil" do
    text = <<~TXT
      Surface habitable Loi Carrez/Boutin : 95 m²
      Type de logement : Maison individuelle — 92 m²
    TXT
    assert_nil SurfaceRegexFallback.call(text)
  end

  test "accord à 1 m² près (95 vs 94) → retient le plus fréquent" do
    text = <<~TXT
      Surface habitable : 95 m²
      Surface habitable : 95 m²
      Type de logement : Maison individuelle — 94 m²
    TXT
    assert_equal 95, SurfaceRegexFallback.call(text)
  end

  # ─── 4. BORNES ───────────────────────────────────────────────────────

  test "rejette une surface aberrante en-dessous de 9 m²" do
    text = "Surface habitable : 5 m²"
    assert_nil SurfaceRegexFallback.call(text)
  end

  test "rejette une surface aberrante au-delà de 1000 m²" do
    # Garde \d{2,3} → max 999. On vérifie qu'un nombre à 4 chiffres
    # juste à côté du contexte n'est pas non plus capturé.
    text = "Surface habitable : 9999 m²"
    assert_nil SurfaceRegexFallback.call(text)
  end

  # ─── 5. ENTRÉES DÉGÉNÉRÉES ──────────────────────────────────────────

  test "texte vide → nil" do
    assert_nil SurfaceRegexFallback.call("")
  end

  test "nil en entrée → nil" do
    assert_nil SurfaceRegexFallback.call(nil)
  end

  test "texte sans aucune mention de surface → nil" do
    text = "Document de copropriété : assemblée générale du 12 septembre 2024."
    assert_nil SurfaceRegexFallback.call(text)
  end
end
