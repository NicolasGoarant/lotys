require "test_helper"

# Grille de rétro-déduction de l'état d'isolation par période de construction.
# Spec : docs/MODELE_DPE_3CL.md §3bis.
#
# Discipline : la grille est une SOURCE DE VÉRITÉ UNIQUE, lue par
# tmp/validate_dpe_engine.rb et par tout futur consommateur. Pas de copie
# locale (cf. piège DPE_IMPACT / table énergie).
#
# C'est un repli de DERNIER RECOURS (source :deduit). N'écrase jamais une
# donnée réelle ; merge_with_extracted en est la garantie testable.

class InsulationDecadeGridTest < ActiveSupport::TestCase
  # ── Tranche 1 : avant 1974 (aucune RT, §3 du doc) ──────────────────────
  test "1900 (bâti très ancien) → tout :non_isole" do
    r = InsulationDecadeGrid.call(1900)
    assert_equal({ murs: :non_isole, toiture: :non_isole, menuiseries: :non_isole }, r)
  end

  test "1962 (bien oracle Lauze ID 107) → tout :non_isole — cohérent §3 et oracle F" do
    r = InsulationDecadeGrid.call(1962)
    assert_equal :non_isole, r[:murs]
    assert_equal :non_isole, r[:toiture]
    assert_equal :non_isole, r[:menuiseries]
  end

  test "1973 (borne haute pré-RT) → :non_isole" do
    assert_equal :non_isole, InsulationDecadeGrid.call(1973)[:murs]
  end

  # ── Tranche 2 : 1974-1982 (RT 1974) ─────────────────────────────────────
  test "1974 (borne basse RT 1974) → :non_isole (la RT 1974 limite mais ne généralise pas l'isolation)" do
    r = InsulationDecadeGrid.call(1974)
    assert_equal :non_isole, r[:murs]
    assert_equal :non_isole, r[:toiture]
  end

  test "1982 (borne haute RT 1974) → :non_isole" do
    assert_equal :non_isole, InsulationDecadeGrid.call(1982)[:murs]
  end

  # ── Tranche 3 : 1983-1989 (RT 1982 / RT 1988) ──────────────────────────
  test "1983 (borne basse RT 1982/1988) → murs :partiel, menuiseries encore :non_isole (vitrage simple dominant)" do
    r = InsulationDecadeGrid.call(1983)
    assert_equal :partiel,   r[:murs]
    assert_equal :partiel,   r[:toiture]
    assert_equal :non_isole, r[:menuiseries], "double émergent pas encore généralisé en 1983"
  end

  test "1985 (milieu RT 1982/1988) → murs :partiel" do
    assert_equal :partiel, InsulationDecadeGrid.call(1985)[:murs]
  end

  test "1989 (borne haute RT 1982/1988) → murs :partiel, menuiseries :non_isole" do
    r = InsulationDecadeGrid.call(1989)
    assert_equal :partiel,   r[:murs]
    assert_equal :non_isole, r[:menuiseries]
  end

  # ── Tranche 4 : 1990-2000 (RT 1988 / RT 2000) ──────────────────────────
  test "1990 (borne basse RT 1988/2000) → :partiel, menuiseries :partiel (double émergent)" do
    r = InsulationDecadeGrid.call(1990)
    assert_equal :partiel, r[:murs]
    assert_equal :partiel, r[:menuiseries], "double vitrage émergent à partir de 1990"
  end

  # TEST DÉCISIF — bien ID 69 (Nancy, 1995, classé D au DPE réel)
  test "1995 (bien ID 69) → murs :partiel, PAS :non_isole — corrige la dette (a)" do
    r = InsulationDecadeGrid.call(1995)
    assert_equal :partiel, r[:murs],
      "TEST DÉCISIF : ID 69 classé D réel — le seuil binaire <2000 = :non_isole " \
      "le calculait F/G (écart -2). La grille §3bis doit le mettre en :partiel " \
      "pour que la classe remonte vers E/D."
    assert_equal :partiel, r[:toiture]
    assert_equal :partiel, r[:menuiseries]
  end

  test "2000 (borne haute RT 1988/2000) → :partiel" do
    assert_equal :partiel, InsulationDecadeGrid.call(2000)[:murs]
  end

  # ── Tranche 5 : 2001-2006 (RT 2000) ─────────────────────────────────────
  test "2001 (borne basse RT 2000) → tout :isole — isolation systématique" do
    r = InsulationDecadeGrid.call(2001)
    assert_equal :isole, r[:murs]
    assert_equal :isole, r[:toiture]
    assert_equal :isole, r[:menuiseries]
  end

  test "2003 (milieu RT 2000) → :isole" do
    assert_equal :isole, InsulationDecadeGrid.call(2003)[:murs]
  end

  test "2006 (borne haute RT 2000) → :isole" do
    assert_equal :isole, InsulationDecadeGrid.call(2006)[:murs]
  end

  # ── Tranche 6 : 2007-2012 (RT 2005) ─────────────────────────────────────
  test "2007 (borne basse RT 2005) → :isole" do
    assert_equal :isole, InsulationDecadeGrid.call(2007)[:murs]
  end

  test "2012 (borne haute RT 2005) → :isole" do
    assert_equal :isole, InsulationDecadeGrid.call(2012)[:murs]
  end

  # ── Tranche 7 : 2013+ (RT 2012 / RE 2020) ──────────────────────────────
  test "2013 (RT 2012 BBC) → :isole" do
    assert_equal :isole, InsulationDecadeGrid.call(2013)[:murs]
  end

  test "2015 (RT 2012 en vitesse de croisière) → :isole" do
    assert_equal :isole, InsulationDecadeGrid.call(2015)[:murs]
  end

  test "2025 (RE 2020) → :isole" do
    assert_equal :isole, InsulationDecadeGrid.call(2025)[:murs]
  end

  # ── Année inconnue : repli conservateur ────────────────────────────────
  test "construction_year nil → :non_isole partout (défaut conservateur, pas d'invention)" do
    r = InsulationDecadeGrid.call(nil)
    assert_equal :non_isole, r[:murs]
    assert_equal :non_isole, r[:toiture]
    assert_equal :non_isole, r[:menuiseries]
  end

  # ── property_type accepté mais non utilisé pour l'instant ──────────────
  test "property_type fourni n'altère pas le résultat (paramètre accepté, non utilisé)" do
    sans = InsulationDecadeGrid.call(1995)
    avec_maison = InsulationDecadeGrid.call(1995, property_type: "maison")
    avec_appart = InsulationDecadeGrid.call(1995, property_type: "appartement")
    assert_equal sans, avec_maison
    assert_equal sans, avec_appart
  end

  # ──────────────────────────────────────────────────────────────────────
  # NON-ÉCRASEMENT — la grille est un repli, source :deduit
  # ──────────────────────────────────────────────────────────────────────

  test "merge_with_extracted : extrait :isole pour murs prime sur grille :partiel (1995)" do
    r = InsulationDecadeGrid.merge_with_extracted(1995, extracted: { murs: :isole })
    assert_equal :isole,   r[:murs],
      "Source :extrait ne doit JAMAIS être écrasée par la grille :deduit"
    assert_equal :partiel, r[:toiture], "la grille s'applique aux postes non extraits"
    assert_equal :partiel, r[:menuiseries]
  end

  test "merge_with_extracted : extrait :non_isole pour toiture prime sur grille :isole (2010)" do
    r = InsulationDecadeGrid.merge_with_extracted(2010, extracted: { toiture: :non_isole })
    assert_equal :isole,     r[:murs]
    assert_equal :non_isole, r[:toiture],
      "Même quand l'extrait dit pire que la grille, il prime (la grille est un repli)"
    assert_equal :isole,     r[:menuiseries]
  end

  test "merge_with_extracted : extrait vide → résultat = grille pure" do
    pure   = InsulationDecadeGrid.call(1995)
    merged = InsulationDecadeGrid.merge_with_extracted(1995, extracted: {})
    assert_equal pure, merged
  end

  test "merge_with_extracted : extrait avec valeur nil ignoré (compactage)" do
    r = InsulationDecadeGrid.merge_with_extracted(1995, extracted: { murs: nil, toiture: :isole })
    assert_equal :partiel, r[:murs],     "nil dans extracted = pas de donnée → grille s'applique"
    assert_equal :isole,   r[:toiture],  "valeur non-nil prime"
  end
end
