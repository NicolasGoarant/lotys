require "test_helper"
require "open3"
require "json"

# Tests des deux fonctions pures de app/javascript/dpe_slider_logic.js :
#
#   - deriveSelectionForTarget  : classe cible → sélection travaux à cocher.
#   - deriveTargetFromSelection : cases cochées → classe atteignable (label).
#
# Post-fix anomalies 1 et 2 :
#   ANOMALIE 1 — deriveTargetFromSelection plafonne désormais à currentDpeIdx
#   (jamais pire que la classe actuelle). Fix du cas prod "toiture seule
#   cochée → OBJECTIF : G" alors que la classe actuelle est F.
#
#   ANOMALIE 2 — deriveSelectionForTarget énumère TOUTES les combinaisons
#   de la matrice (plus juste les préfixes de priorite), permettant
#   d'atteindre les classes seulement accessibles par une combinaison
#   non-préfixe (ex : E via isolation_toiture seule quand murs seul donne D).
#   Signature : (currentDpeIdx, targetIdx, combinaisons, travauxCosts).
#
# Stratégie : exécuter le JS via `node` en CLI, parser le JSON retourné.
# Pas de runner JS, pas de bundler.
class DpeSliderLogicTest < ActiveSupport::TestCase
  NODE_BIN   = "node".freeze
  LOGIC_FILE = Rails.root.join("app/javascript/dpe_slider_logic.js").to_s.freeze

  # ── Matrice synthétique (chaîne monotone de préfixes) ──────────────────
  # Bien F, cascade classique où ajouter des gestes descend la classe.
  # Une seule entrée par classe → pas de choix ambigu pour l'algo cheapest.
  COMBI_SYNTH = {
    ""                                                                                              => { "classe" => "F" },  # 0 gestes
    "isolation_murs"                                                                                => { "classe" => "E" },  # 1
    "chauffage,isolation_murs"                                                                      => { "classe" => "D" },  # 2
    "chauffage,isolation_murs,isolation_toiture"                                                    => { "classe" => "C" },  # 3
    "chauffage,isolation_murs,isolation_toiture,menuiseries"                                        => { "classe" => "B" },  # 4
    "chauffage,isolation_murs,isolation_toiture,menuiseries,vmc"                                    => { "classe" => "B" },  # 5
    "chauffage,isolation_murs,isolation_plancher_bas,isolation_toiture,menuiseries,vmc"             => { "classe" => "B" },  # 6
    "chauffage,chauffe_eau,isolation_murs,isolation_plancher_bas,isolation_toiture,menuiseries,vmc" => { "classe" => "A" }   # 7
  }.freeze

  # Coûts MONOTONES CROISSANTS : chaque geste coûte plus cher que la somme
  # de tous les précédents. Garantit que quand plusieurs combinaisons
  # atteignent la même classe (comme B ci-dessus, atteignable en k=4/5/6),
  # la MOINS CHÈRE est le plus petit préfixe.
  # (En prod, les coûts viennent de data-mediane sur .travail-check —
  # PropertyAnalysisService les calcule à partir de Claude. On simule ici
  # l'ordre naturel « murs plus léger que menuiseries plus léger que VMC ».)
  COSTS_SYNTH = {
    "isolation_murs"         => 1,
    "chauffage"              => 10,
    "isolation_toiture"      => 100,
    "menuiseries"            => 1_000,
    "vmc"                    => 10_000,
    "isolation_plancher_bas" => 100_000,
    "chauffe_eau"            => 1_000_000
  }.freeze

  setup do
    _, err, st = Open3.capture3(NODE_BIN, "-v")
    skip "node CLI absent du PATH du runner (#{err.strip})." unless st.success?
  end

  # ── Helpers ────────────────────────────────────────────────────────────
  def run_derive(input)
    payload = input.to_json
    script = <<~JS
      const { deriveSelectionForTarget } = require(#{LOGIC_FILE.inspect});
      console.log(JSON.stringify(deriveSelectionForTarget(JSON.parse(process.argv[1]))));
    JS
    out, err, st = Open3.capture3(NODE_BIN, "-e", script, payload)
    raise "node failed (#{st.exitstatus}): #{err}" unless st.success?
    JSON.parse(out)
  end

  def derive_matrice(current_dpe_idx:, target_idx:,
                     combinaisons: COMBI_SYNTH, costs: COSTS_SYNTH)
    run_derive(
      currentDpeIdx: current_dpe_idx,
      targetIdx:     target_idx,
      combinaisons:  combinaisons,
      travauxCosts:  costs
    )
  end

  def run_target(codes_actifs, combinaisons: COMBI_SYNTH, current_dpe_idx: 5)
    payload = {
      codesActifs:   codes_actifs,
      combinaisons:  combinaisons,
      currentDpeIdx: current_dpe_idx
    }.to_json
    script = <<~JS
      const { deriveTargetFromSelection } = require(#{LOGIC_FILE.inspect});
      console.log(JSON.stringify(deriveTargetFromSelection(JSON.parse(process.argv[1]))));
    JS
    out, err, st = Open3.capture3(NODE_BIN, "-e", script, payload)
    raise "node failed (#{st.exitstatus}): #{err}" unless st.success?
    JSON.parse(out)
  end

  # ═════════════════════════════════════════════════════════════════════════
  # deriveSelectionForTarget — sens JAUGE → CASES (drag slider)
  # ═════════════════════════════════════════════════════════════════════════

  # ─── P. CHEMIN-INDÉPENDANCE ────────────────────────────────────────────
  test "P — chemin-indépendance : deux appels avec mêmes args ⇒ même sélection" do
    cur = 5
    [5, 4, 3, 2, 1, 0].each do |tgt|
      a = derive_matrice(current_dpe_idx: cur, target_idx: tgt)
      b = derive_matrice(current_dpe_idx: cur, target_idx: tgt)
      assert_equal a["checked"].sort, b["checked"].sort,
        "tgt=#{tgt} : deux appels doivent donner la même sélection"
    end
  end

  # ─── Q. CASCADE MONOTONE (préservée par les coûts monotones) ───────────
  # Coûts monotones ⇒ pour une classe atteignable par plusieurs
  # combinaisons, la moins chère est le plus petit préfixe de la chaîne.
  # La cascade reste donc monotone-emboîtée pour COMBI_SYNTH.
  test "Q — cascade monotone : chaque cible plus ambitieuse est un sur-ensemble de la précédente" do
    cur = 5
    cibles = [5, 4, 3, 2, 1, 0]
    selections = cibles.map { |tgt| derive_matrice(current_dpe_idx: cur, target_idx: tgt)["checked"] }

    cibles.each_with_index do |tgt, i|
      next if i == 0
      perdus = selections[i - 1] - selections[i]
      assert_empty perdus,
        "Passer de tgt=#{cibles[i - 1]} à tgt=#{tgt} (plus ambitieuse) ne doit pas perdre de geste. " \
        "Perdus: #{perdus.inspect}"
    end

    cibles.each_with_index do |_tgt, i|
      next if i == 0
      assert_operator selections[i].size, :>=, selections[i - 1].size
    end
  end

  # ─── Q-bis. Cascade spécifique au bien ─────────────────────────────────
  # Sur COMBI_SYNTH, la seule combinaison atteignant E est [isolation_murs].
  test "Q-bis — cible E sur bien :partiel coche isolation_murs uniquement" do
    r = derive_matrice(current_dpe_idx: 5, target_idx: 4)
    assert_equal ["isolation_murs"], r["checked"]
  end

  # ─── I. MENUISERIES stables pour cible ambitieuse B ────────────────────
  test "I — cible B : menuiseries incluse et stable sur 5 appels" do
    5.times do |i|
      r = derive_matrice(current_dpe_idx: 5, target_idx: 1)
      assert_includes r["checked"], "menuiseries",
        "Appel ##{i + 1} : menuiseries doit être dans la sélection F→B"
    end
  end

  # ─── N. PURETÉ — entrées non mutées, idempotent ────────────────────────
  test "N — pureté : idempotent et n'altère pas combinaisons ni travauxCosts" do
    script = <<~JS
      const { deriveSelectionForTarget } = require(#{LOGIC_FILE.inspect});
      const combinaisons = #{COMBI_SYNTH.to_json};
      const travauxCosts = #{COSTS_SYNTH.to_json};
      const snapshotBefore = JSON.stringify({ combinaisons, travauxCosts });
      const input = { currentDpeIdx: 5, targetIdx: 2, combinaisons, travauxCosts };
      const res1 = deriveSelectionForTarget(input);
      const res2 = deriveSelectionForTarget(input);
      const snapshotAfter = JSON.stringify({ combinaisons, travauxCosts });
      console.log(JSON.stringify({
        idempotent:   JSON.stringify(res1) === JSON.stringify(res2),
        inputsIntact: snapshotBefore === snapshotAfter
      }));
    JS
    _, err, st = Open3.capture3(NODE_BIN, "-e", script)
    out, = Open3.capture3(NODE_BIN, "-e", script)
    assert st.success?, "node script a échoué : #{err}"
    data = JSON.parse(out)
    assert data["idempotent"],   "Idempotence"
    assert data["inputsIntact"], "Non-mutation"
  end

  # ─── ANOMALIE 2 — classes seulement accessibles par NON-préfixe ────────
  # Reproduit le bug prod : sur ce bien, E est atteignable UNIQUEMENT via
  # isolation_toiture SEULE (pas via un préfixe de priorite). L'ancien
  # algo « cascade sur préfixes » court-circuitait vers murs+D (mieux
  # que E), le pin rebondissait vers D. L'énumération trouve désormais
  # exactement E.
  test "anomalie 2 — cible E atteignable via combinaison non-préfixe (toiture seule)" do
    combi = {
      ""                                => { "classe" => "F" },
      "isolation_toiture"               => { "classe" => "E" },  # non-préfixe : atteint E seul
      "isolation_murs"                  => { "classe" => "D" },  # murs seul saute à D (skip E)
      "isolation_murs,isolation_toiture"=> { "classe" => "C" }
    }
    costs = { "isolation_toiture" => 100, "isolation_murs" => 50 }

    r = derive_matrice(current_dpe_idx: 5, target_idx: 4,
                       combinaisons: combi, costs: costs)
    assert_equal ["isolation_toiture"], r["checked"],
      "Cible E doit trouver la combinaison non-préfixe isolation_toiture seule, " \
      "au lieu de rebondir sur murs seul (D). Obtenu : #{r["checked"].inspect}"
  end

  # ─── ANOMALIE 2 — stabilité slider : glisser deux fois sur X donne pareil ─
  # Verrou anti-régression : pour CHAQUE classe atteignable via COMBI_SYNTH,
  # deux drags successifs sur la même classe produisent le même ensemble.
  test "stabilité slider : deux drags sur la même classe donnent la même sélection" do
    cur = 5
    [0, 1, 2, 3, 4].each do |tgt|
      a = derive_matrice(current_dpe_idx: cur, target_idx: tgt)
      b = derive_matrice(current_dpe_idx: cur, target_idx: tgt)
      assert_equal a["checked"], b["checked"],
        "tgt=#{tgt} : deux drags successifs doivent produire exactement la même sélection"
    end
  end

  # ─── ANOMALIE 2 — bouclage : drag → sélection → classe → == demandée ──
  # Pour chaque classe A→E, drag produit une sélection dont la classe
  # dérivée est EXACTEMENT la classe demandée (pas de rebond).
  test "bouclage jauge↔travaux : drag sur X → sélection → classe dérivée == X (pas de rebond)" do
    cur = 5
    [0, 1, 2, 3, 4].each do |tgt|
      selection = derive_matrice(current_dpe_idx: cur, target_idx: tgt)["checked"]
      classe_derivee = run_target(selection, current_dpe_idx: cur)
      assert_equal tgt, classe_derivee,
        "Boucle rompue pour tgt=#{tgt} : drag produit #{selection.inspect} qui dérive à #{classe_derivee}, " \
        "attendu #{tgt}. Le pin va rebondir."
    end
  end

  # ─── ANOMALIE 2 — cible inatteignable → pessimiste, jamais mieux ──────
  # Si la classe demandée n'existe dans aucune combinaison, l'algo
  # retombe sur la classe atteignable la plus proche CÔTÉ PIRE (jamais
  # mieux que demandé).
  test "cible inatteignable → pessimiste (classe plus proche > cible, jamais mieux)" do
    # Bien F. Matrice : F et D seulement — E n'existe nulle part.
    combi = {
      ""                => { "classe" => "F" },
      "isolation_murs"  => { "classe" => "D" }
    }
    costs = { "isolation_murs" => 10 }

    # Cible E (4) inatteignable. Pessimiste = F (5, > E) plutôt que D (3, < E).
    r = derive_matrice(current_dpe_idx: 5, target_idx: 4,
                       combinaisons: combi, costs: costs)
    assert_equal [], r["checked"],
      "Cible E inatteignable : plutôt F (rien coché, jamais mieux que demandé) que D (murs, mieux que demandé). " \
      "Obtenu : #{r["checked"].inspect}"
  end

  # ═════════════════════════════════════════════════════════════════════════
  # deriveTargetFromSelection — sens CASES → JAUGE (source de vérité label)
  # ═════════════════════════════════════════════════════════════════════════

  # ─── Cas nominal ──────────────────────────────────────────────────────
  test "T-nominal : combinaison connue → idx de la classe atteignable" do
    assert_equal 3, run_target(%w[isolation_murs chauffage])
    assert_equal 2, run_target(%w[isolation_murs chauffage isolation_toiture])
    assert_equal 5, run_target([])
  end

  # ─── ANOMALIE 1 — plafond anti-dégradation ────────────────────────────
  # Reproduit et fixe le bug prod « aucun travail coché → OBJECTIF : G »
  # sur un bien F. Cause : la matrice recalcule la classe initiale via
  # PropertyDpeService sur un état reconstruit ; ce recalcul aboutit
  # parfois à G alors que Property#dpe_class (source Claude) dit F. Le
  # plafond évite d'afficher un objectif pire que la classe actuelle.
  test "anomalie 1 — aucun travail coché → objectif == classe actuelle, jamais pire" do
    # Matrice buggy : "" donne G (idx 6), alors que le bien est F (idx 5).
    combi_buggy = { "" => { "classe" => "G" } }
    r = run_target([], combinaisons: combi_buggy, current_dpe_idx: 5)
    assert_equal 5, r,
      "Bien F + aucun travail : label doit rester F (pas d'amélioration), pas G (dégradation absurde). " \
      "Obtenu : #{r} (attendu 5=F)"
  end

  test "anomalie 1 — un seul geste mineur qui dégraderait selon le moteur → plafonné à F" do
    # Matrice buggy : toiture seule fait passer à G selon le moteur (absurde).
    combi_buggy = {
      ""                  => { "classe" => "F" },
      "isolation_toiture" => { "classe" => "G" }
    }
    r = run_target(%w[isolation_toiture], combinaisons: combi_buggy, current_dpe_idx: 5)
    assert_equal 5, r,
      "Un geste d'isolation ne peut PAS afficher un objectif pire que la classe actuelle. " \
      "Plafond min(idx_matrice, currentDpeIdx) actif."
  end

  test "anomalie 1 — invariant : deriveTargetFromSelection ne retourne JAMAIS > currentDpeIdx" do
    # Balaye les 8 combinaisons de COMBI_SYNTH — pour chacune, l'objectif
    # doit être <= currentDpeIdx. C'est le cœur de l'invariant produit.
    cur = 5
    COMBI_SYNTH.each_key do |cle|
      codes = cle == "" ? [] : cle.split(",")
      idx = run_target(codes, current_dpe_idx: cur)
      assert_operator idx, :<=, cur,
        "Combinaison #{codes.inspect} : idx retourné (#{idx}) > currentDpeIdx (#{cur}). " \
        "Le plafond anti-dégradation a été percé."
    end
  end

  # ─── Fallbacks pessimistes ────────────────────────────────────────────
  test "T-fallback : combinaison manquante → currentDpeIdx" do
    assert_equal 5, run_target(%w[menuiseries], current_dpe_idx: 5)
  end

  test "T-fallback : matrice absente (null) → currentDpeIdx" do
    assert_equal 4, run_target(%w[isolation_murs], combinaisons: nil, current_dpe_idx: 4)
  end

  test "T-fallback : classe non-string → currentDpeIdx" do
    combi = { "isolation_murs" => { "classe" => nil } }
    assert_equal 5, run_target(%w[isolation_murs], combinaisons: combi, current_dpe_idx: 5)
  end

  test "T-fallback : classe hors A-G → currentDpeIdx" do
    combi = { "isolation_murs" => { "classe" => "Z" } }
    assert_equal 5, run_target(%w[isolation_murs], combinaisons: combi, current_dpe_idx: 5)
  end

  # ─── Déterminisme + ordre invariant ───────────────────────────────────
  test "T-déterminisme : même codesActifs → même objectif à chaque appel" do
    codes = %w[isolation_murs chauffage isolation_toiture]
    r = 5.times.map { run_target(codes) }
    assert_equal [r.first] * 5, r
  end

  test "T-ordre-invariant : réordonner codesActifs ne change pas l'objectif" do
    a = run_target(%w[isolation_murs chauffage isolation_toiture])
    b = run_target(%w[isolation_toiture chauffage isolation_murs])
    assert_equal a, b
  end

  # ─── Check / uncheck / recheck ────────────────────────────────────────
  test "T-check-uncheck : décocher fait remonter, recocher fait redescendre au même idx" do
    c = run_target(%w[chauffage isolation_murs isolation_toiture])
    assert_equal 2, c
    d = run_target(%w[chauffage isolation_murs])
    assert_equal 3, d
    assert_operator d, :>, c
    c_again = run_target(%w[chauffage isolation_murs isolation_toiture])
    assert_equal c, c_again
  end

  # ─── Purity ──────────────────────────────────────────────────────────
  test "T-purity : deriveTargetFromSelection ne mute pas ses entrées" do
    script = <<~JS
      const { deriveTargetFromSelection } = require(#{LOGIC_FILE.inspect});
      const codes = #{%w[isolation_murs chauffage].to_json};
      const combi = #{COMBI_SYNTH.to_json};
      const snapshotBefore = JSON.stringify({ codes, combi });
      deriveTargetFromSelection({ codesActifs: codes, combinaisons: combi, currentDpeIdx: 5 });
      deriveTargetFromSelection({ codesActifs: codes, combinaisons: combi, currentDpeIdx: 5 });
      const snapshotAfter = JSON.stringify({ codes, combi });
      console.log(JSON.stringify({ intact: snapshotBefore === snapshotAfter }));
    JS
    out, err, st = Open3.capture3(NODE_BIN, "-e", script)
    assert st.success?, "node script a échoué : #{err}"
    assert JSON.parse(out)["intact"]
  end
end
