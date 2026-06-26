require "test_helper"

# Table de normalisation libellé libre → énergie 3CL.
# Source de vérité unique : PropertyDataExtractorService et
# tmp/validate_dpe_engine.rb DOIVENT lire cette table, pas en garder une copie
# (cf. piège DPE_IMPACT JS/Ruby divergents).
class HeatingEnergyNormalizerTest < ActiveSupport::TestCase
  # ── Famille gaz ─────────────────────────────────────────────────────────
  test "« Chaudière gaz ancienne (> 25 ans) » → :gaz (cas oracle ID 107)" do
    assert_equal :gaz, HeatingEnergyNormalizer.call("Chaudière gaz ancienne (> 25 ans)")
  end

  test "« chauffage collectif au gaz » → :gaz (cas ID 72)" do
    assert_equal :gaz, HeatingEnergyNormalizer.call("chauffage collectif au gaz")
  end

  # ── Famille fioul ───────────────────────────────────────────────────────
  test "« Chauffage au fioul collectif » → :fioul (cas ID 64)" do
    assert_equal :fioul, HeatingEnergyNormalizer.call("Chauffage au fioul collectif")
  end

  test "« Mazout » → :fioul (synonyme)" do
    assert_equal :fioul, HeatingEnergyNormalizer.call("Mazout")
  end

  # ── Famille électrique ──────────────────────────────────────────────────
  test "« Radiateurs électriques à inertie » → :electricite (cas ID 71)" do
    assert_equal :electricite, HeatingEnergyNormalizer.call("Radiateurs électriques à inertie NFC (individuel)")
  end

  test "« convecteurs effet Joule » → :electricite" do
    assert_equal :electricite, HeatingEnergyNormalizer.call("convecteurs effet Joule")
  end

  # ── Famille PAC ─────────────────────────────────────────────────────────
  test "« pompe à chaleur air/eau » → :pac" do
    assert_equal :pac, HeatingEnergyNormalizer.call("pompe à chaleur air/eau")
  end

  test "« PAC géothermique » → :pac" do
    assert_equal :pac, HeatingEnergyNormalizer.call("PAC géothermique")
  end

  # ── Famille bois ────────────────────────────────────────────────────────
  test "« Poêle à granulés » → :bois" do
    assert_equal :bois, HeatingEnergyNormalizer.call("Poêle à granulés")
  end

  test "« Chaudière bois bûches » → :bois" do
    assert_equal :bois, HeatingEnergyNormalizer.call("Chaudière bois bûches")
  end

  # ── Cas dégradés → :inconnue ────────────────────────────────────────────
  test "libellé vide → :inconnue (pas d'invention)" do
    assert_equal :inconnue, HeatingEnergyNormalizer.call("")
  end

  test "nil → :inconnue" do
    assert_equal :inconnue, HeatingEnergyNormalizer.call(nil)
  end

  test "libellé non reconnu → :inconnue (« Panneau solaire seul »)" do
    assert_equal :inconnue, HeatingEnergyNormalizer.call("Panneau solaire")
  end

  # ── Priorité dans la table (ordre des regex) ────────────────────────────
  test "« PAC électrique » → :pac (PAC avant électrique générique)" do
    # Une PAC consomme de l'électricité mais le moteur 3CL la traite via COP
    # (≠ convecteur ×1,9). La table doit privilégier la classification fine.
    assert_equal :pac, HeatingEnergyNormalizer.call("Pompe à chaleur électrique")
  end

  test "« poêle à bois » → :bois (poêle match avant bois générique, même résultat)" do
    assert_equal :bois, HeatingEnergyNormalizer.call("poêle à bois récent")
  end
end
