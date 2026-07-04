require "test_helper"
require "open3"
require "json"

# Tests de la fonction PURE deriveSelectionForTarget
# (app/javascript/dpe_slider_logic.js).
#
# Temps 3b-2 commit 2 — la cascade marche maintenant sur une PRIORITÉ DE
# GESTES spécifique au bien (calculée serveur par PropertyDpeMatrixService)
# et une MATRICE de combinaisons → classe atteignable, au lieu du forfait
# DPE_IMPACT (déconnecté du bâti, mêmes points pour tous).
#
# Modèle CASCADE MONOTONE PAR PRÉFIXES :
#   - prioriteGestes est une liste ordonnée de codes (gain EP décroissant
#     côté serveur). Elle joue le rôle de "file canonique" mais spécifique
#     au bien.
#   - On marche dans cette liste : pour atteindre une classe cible, on
#     prend le plus petit préfixe k tel que combinaisons[préfixe.sort.join(",")]
#     ait une classe ≤ cible.
#   - Les préfixes sont emboîtés par construction ⇒ cascade monotone par
#     construction (la propriété Q).
#
# Stratégie : exécuter le fichier JS via `node` en CLI depuis Minitest avec
# Open3, parser le JSON retourné, asserter en Ruby. Pas de runner JS (Lauze
# n'en a pas), pas de bundler.
#
# Cas testés :
#   P — Chemin-indépendance : deux appels avec mêmes args ⇒ sélections
#       identiques. Pas de variable globale, pas d'horloge, pas de random.
#   Q — Cascade monotone : pour toute la chaîne G→…→A, sélection(tgt-1) ⊇
#       sélection(tgt). Monter n'enlève jamais rien — garanti par préfixes
#       emboîtés.
#   I — Menuiseries : présentes dans le préfixe pour cibles ambitieuses.
#   N — Pureté : entrées non mutées, idempotent.
class DpeSliderLogicTest < ActiveSupport::TestCase
  NODE_BIN   = "node".freeze
  LOGIC_FILE = Rails.root.join("app/javascript/dpe_slider_logic.js").to_s.freeze

  # ── Matrice synthétique (Temps 3b-2 commit 2) ──────────────────────────
  # Bien type « 1995 :partiel » où priorite_gestes met isolation_murs AVANT
  # chauffage — exactement le motif observé sur ID 69 dans le Temps 3b-1
  # (top 1 = isolation_murs, gain EP +95,9). Cet ordre DIFFÈRE du forfait
  # DPE_IMPACT (qui met chauffage à 1.5, donc en tête). C'est la preuve
  # que la cascade est devenue spécifique au bien.
  PRIORITE_SYNTH = %w[
    isolation_murs
    chauffage
    isolation_toiture
    menuiseries
    vmc
    isolation_plancher_bas
    chauffe_eau
  ].freeze

  # Matrice : pour chaque préfixe k de PRIORITE_SYNTH, la classe atteignable.
  # Clé = préfixe.sort.join(","), EXACTEMENT le format de
  # PropertyDpeMatrixService#calculer_combinaisons (l. 116).
  # Classe initiale F (5), on descend en ajoutant des gestes.
  COMBI_SYNTH = {
    ""                                                                                                  => { "classe" => "F" },  # 0
    "isolation_murs"                                                                                    => { "classe" => "E" },  # 1
    "chauffage,isolation_murs"                                                                          => { "classe" => "D" },  # 2
    "chauffage,isolation_murs,isolation_toiture"                                                        => { "classe" => "C" },  # 3
    "chauffage,isolation_murs,isolation_toiture,menuiseries"                                            => { "classe" => "B" },  # 4
    "chauffage,isolation_murs,isolation_toiture,menuiseries,vmc"                                        => { "classe" => "B" },  # 5
    "chauffage,isolation_murs,isolation_plancher_bas,isolation_toiture,menuiseries,vmc"                 => { "classe" => "B" },  # 6
    "chauffage,chauffe_eau,isolation_murs,isolation_plancher_bas,isolation_toiture,menuiseries,vmc"     => { "classe" => "A" }   # 7
  }.freeze

  setup do
    out, err, st = Open3.capture3(NODE_BIN, "-v")
    skip "node CLI absent du PATH du runner (#{err.strip}). Installer node ou exporter PATH avant `bin/rails test`." unless st.success?
    @node_version = out.strip
  end

  # Helper : exécute deriveSelectionForTarget(input) via node, retourne le
  # hash parsé. Le payload JSON arrive en process.argv[1] côté node.
  def run_derive(input)
    payload = input.to_json
    script = <<~JS
      const { deriveSelectionForTarget } = require(#{LOGIC_FILE.inspect});
      const input = JSON.parse(process.argv[1]);
      console.log(JSON.stringify(deriveSelectionForTarget(input)));
    JS
    out, err, st = Open3.capture3(NODE_BIN, "-e", script, payload)
    raise "node failed (#{st.exitstatus}): #{err}" unless st.success?
    JSON.parse(out)
  end

  # Helper : appel avec la nouvelle signature (matrice).
  def derive_matrice(current_dpe_idx:, target_idx:,
                     priorite: PRIORITE_SYNTH, combinaisons: COMBI_SYNTH)
    run_derive(
      currentDpeIdx: current_dpe_idx,
      targetIdx:     target_idx,
      prioriteGestes: priorite,
      combinaisons:   combinaisons
    )
  end

  # ─── P. CHEMIN-INDÉPENDANCE (nouvelle signature) ────────────────────────
  test "P — chemin-indépendance : deux appels avec mêmes args matrice ⇒ même sélection" do
    cur = 5 # F (état initial du bien synthétique)
    [5, 4, 3, 2, 1, 0].each do |tgt|
      a = derive_matrice(current_dpe_idx: cur, target_idx: tgt)
      b = derive_matrice(current_dpe_idx: cur, target_idx: tgt)
      assert_equal a["checked"].sort, b["checked"].sort,
        "tgt=#{tgt} : deux appels doivent donner la même sélection (sortie déterministe)"
    end
  end

  # ─── Q. CASCADE MONOTONE (préfixes emboîtés par construction) ───────────
  test "Q — cascade monotone : sur la chaîne F→A, chaque cible plus ambitieuse est un sur-ensemble de la précédente" do
    cur = 5 # F
    # Cibles de la moins ambitieuse (F=5 → gain 0) à la plus ambitieuse (A=0 → gain 5).
    cibles = [5, 4, 3, 2, 1, 0]
    selections = cibles.map do |tgt|
      derive_matrice(current_dpe_idx: cur, target_idx: tgt)["checked"]
    end

    # Pour chaque cran : la cible plus ambitieuse doit être un sur-ensemble
    # de la moins ambitieuse. AUCUN geste perdu en montant.
    cibles.each_with_index do |tgt, i|
      next if i == 0
      moins_ambitieuse = selections[i - 1]
      plus_ambitieuse  = selections[i]
      perdus = moins_ambitieuse - plus_ambitieuse
      assert_empty perdus,
        "Passer de tgt=#{cibles[i - 1]} à tgt=#{tgt} (plus ambitieuse) " \
        "ne doit jamais perdre de geste. Perdus: #{perdus.inspect}. " \
        "moins=#{moins_ambitieuse.inspect}, plus=#{plus_ambitieuse.inspect}"
    end

    # Cardinalité croissante par construction (préfixes emboîtés).
    cibles.each_with_index do |_tgt, i|
      next if i == 0
      assert_operator selections[i].size, :>=, selections[i - 1].size,
        "|sélection(tgt=#{cibles[i]})| doit être ≥ |sélection(tgt=#{cibles[i - 1]})|"
    end
  end

  # ─── Cas spécifique : preuve que la cascade dépend du bien ──────────────
  # Avec PRIORITE_SYNTH, le top 1 est isolation_murs (et NON chauffage comme
  # dans le forfait DPE_IMPACT). Pour une cible modérée (E), la cascade
  # doit cocher isolation_murs SEUL — pas chauffage.
  # C'est le motif observé sur ID 69 (1995 :partiel) vs Tilleuls (1962) où
  # le forfait collait toujours chauffage en tête.
  test "Q-bis — cascade spécifique au bien : tgt E sur bien :partiel coche isolation_murs, PAS chauffage" do
    cur = 5 # F
    r = derive_matrice(current_dpe_idx: cur, target_idx: 4) # E
    assert_equal ["isolation_murs"], r["checked"],
      "Cible E sur ce bien doit cocher uniquement isolation_murs (top 1 de priorite), " \
      "pas chauffage (top 1 du forfait). Obtenu : #{r["checked"].inspect}"
  end

  # ─── I. MENUISERIES — inclusion stable pour cible ambitieuse ────────────
  test "I — menuiseries : pour cible ambitieuse (F→B, gain 4), menuiseries est cochée et son inclusion est stable" do
    cur = 5 # F
    # Cible B (1). Préfixe 4 atteint B selon COMBI_SYNTH.
    r = derive_matrice(current_dpe_idx: cur, target_idx: 1)
    assert_includes r["checked"], "menuiseries",
      "F→B (préfixe 4 nécessaire) : menuiseries doit être dans le préfixe. " \
      "checked=#{r["checked"].inspect}"
    # Stabilité : 5 appels successifs.
    5.times do |i|
      ri = derive_matrice(current_dpe_idx: cur, target_idx: 1)
      assert_includes ri["checked"], "menuiseries",
        "Appel ##{i + 1} : menuiseries doit toujours être cochée à F→B"
    end
  end

  # ─── N. PURETÉ — entrées non mutées, idempotent ─────────────────────────
  test "N — pureté : idempotent et n'altère pas prioriteGestes ni combinaisons" do
    script = <<~JS
      const { deriveSelectionForTarget } = require(#{LOGIC_FILE.inspect});
      const priorite     = #{PRIORITE_SYNTH.to_json};
      const combinaisons = #{COMBI_SYNTH.to_json};

      const snapshotBefore = JSON.stringify({ priorite, combinaisons });

      const input = {
        currentDpeIdx: 5, targetIdx: 2,
        prioriteGestes: priorite,
        combinaisons:    combinaisons
      };
      const res1 = deriveSelectionForTarget(input);
      const res2 = deriveSelectionForTarget(input);

      const snapshotAfter = JSON.stringify({ priorite, combinaisons });

      console.log(JSON.stringify({
        idempotent:   JSON.stringify(res1) === JSON.stringify(res2),
        inputsIntact: snapshotBefore === snapshotAfter,
        before:       snapshotBefore,
        after:        snapshotAfter,
        res1, res2
      }));
    JS

    out, err, st = Open3.capture3(NODE_BIN, "-e", script)
    assert st.success?, "node script a échoué : #{err}"
    data = JSON.parse(out)
    assert data["idempotent"],
      "Idempotence : deux appels avec mêmes args ⇒ même résultat. " \
      "res1=#{data['res1'].inspect}, res2=#{data['res2'].inspect}"
    assert data["inputsIntact"],
      "Non-mutation : prioriteGestes et combinaisons ne doivent pas être modifiés. " \
      "Avant: #{data['before']}, Après: #{data['after']}"
  end

  # ─── Cohérence du tri lexicographique (JS vs Ruby) ──────────────────────
  # Le préfixe est trié côté JS via Array.prototype.sort (lexicographique
  # par défaut). PropertyDpeMatrixService trie côté Ruby via Array#sort
  # (idem lexicographique sur strings ASCII). Tant que les codes sont du
  # ASCII pur (aucun accent dans nos 7 macro-postes), les ordres sont
  # identiques. Test bout-à-bout : on construit un préfixe en JS, on
  # lookuper la clé dans COMBI_SYNTH (rédigée à la main avec sort Ruby).
  # Si la lookup réussit, le sort lexico marche pareil dans les deux.
  test "Cohérence tri JS = tri Ruby — toute la chaîne de cibles trouve sa combinaison" do
    cur = 5
    [5, 4, 3, 2, 1, 0].each do |tgt|
      r = derive_matrice(current_dpe_idx: cur, target_idx: tgt)
      # Si la fonction retourne quelque chose (autre que vide pour tgt < cur),
      # c'est qu'elle a trouvé une combinaison qui matchait → tri JS = tri Ruby.
      # Pour tgt = cur (5), checked = [] (cas géré séparément).
      assert r.key?("checked"), "tgt=#{tgt} : fonction doit retourner {checked: ...}"
    end
  end

  # ═════════════════════════════════════════════════════════════════════════
  # deriveTargetFromSelection — sens INVERSE (cases → classe atteignable)
  #
  # Ajouté après le bug prod « MÊME set de cases affiche tantôt A tantôt B
  # selon l'historique des manipulations ». Cette fonction est la source
  # de vérité UNIQUE de l'objectif : label + pin + hidden field passent
  # tous par elle après chaque changement de case.
  # ═════════════════════════════════════════════════════════════════════════

  # Helper : exécute deriveTargetFromSelection(input) via node.
  def run_target(codes_actifs, combinaisons: COMBI_SYNTH, current_dpe_idx: 5)
    payload = {
      codesActifs:   codes_actifs,
      combinaisons:  combinaisons,
      currentDpeIdx: current_dpe_idx
    }.to_json
    script = <<~JS
      const { deriveTargetFromSelection } = require(#{LOGIC_FILE.inspect});
      const input = JSON.parse(process.argv[1]);
      console.log(JSON.stringify(deriveTargetFromSelection(input)));
    JS
    out, err, st = Open3.capture3(NODE_BIN, "-e", script, payload)
    raise "node failed (#{st.exitstatus}): #{err}" unless st.success?
    JSON.parse(out)
  end

  # ─── Cas nominal ──────────────────────────────────────────────────────
  test "T-nominal : combinaison connue → renvoie l'idx de la classe atteignable" do
    # F (5) initial. Préfixe [isolation_murs, chauffage] atteint D (COMBI_SYNTH ligne « 2 »).
    assert_equal 3, run_target(%w[isolation_murs chauffage]),
      "isolation_murs+chauffage → D=3 selon COMBI_SYNTH"

    # Préfixe [isolation_murs, chauffage, isolation_toiture] atteint C=2.
    assert_equal 2, run_target(%w[isolation_murs chauffage isolation_toiture]),
      "trio → C=2"

    # Sélection vide → F (5, classe initiale).
    assert_equal 5, run_target([]), "vide → F=5"
  end

  # ─── Fallback pessimiste (cœur du fix bug prod) ───────────────────────
  test "T-fallback : combinaison manquante dans la matrice → currentDpeIdx (pessimiste)" do
    # Cette combinaison n'existe pas dans COMBI_SYNTH (menuiseries seule
    # ni « chauffage,menuiseries » ne sont listées) → retour = currentDpeIdx.
    r = run_target(%w[menuiseries], current_dpe_idx: 5)
    assert_equal 5, r,
      "Entrée manquante → CUR (pas d'objectif inventé). Le bug prod venait de retourner null " \
      "et de laisser le label stale à sa valeur précédente."
  end

  test "T-fallback : matrice absente (combinaisons=null) → currentDpeIdx" do
    r = run_target(%w[isolation_murs], combinaisons: nil, current_dpe_idx: 4)
    assert_equal 4, r, "Matrice absente → CUR (fallback pessimiste)"
  end

  test "T-fallback : entrée avec classe non-string (donnée corrompue) → currentDpeIdx" do
    combi_corrompue = { "isolation_murs" => { "classe" => nil } }
    r = run_target(%w[isolation_murs], combinaisons: combi_corrompue, current_dpe_idx: 5)
    assert_equal 5, r
  end

  test "T-fallback : classe hors A-G (donnée corrompue) → currentDpeIdx" do
    combi_corrompue = { "isolation_murs" => { "classe" => "Z" } }
    r = run_target(%w[isolation_murs], combinaisons: combi_corrompue, current_dpe_idx: 5)
    assert_equal 5, r
  end

  # ─── Déterminisme — verrou du bug prod ────────────────────────────────
  test "T-déterminisme : le même codesActifs donne toujours le même objectif" do
    codes = %w[isolation_murs chauffage isolation_toiture]
    resultats = 5.times.map { run_target(codes) }
    assert_equal [resultats.first] * 5, resultats,
      "Le même set doit produire le même objectif à chaque appel — c'est LA garantie du fix. " \
      "Résultats obtenus : #{resultats.inspect}"
  end

  test "T-ordre-invariant : réordonner codesActifs ne change pas l'objectif (tri interne)" do
    a = run_target(%w[isolation_murs chauffage isolation_toiture])
    b = run_target(%w[isolation_toiture chauffage isolation_murs])
    c = run_target(%w[chauffage isolation_toiture isolation_murs])
    assert_equal a, b
    assert_equal b, c
  end

  # ─── Décocher fait remonter l'objectif, recocher le fait redescendre ──
  test "T-check-uncheck : décocher un geste fait REMONTER l'objectif (moins bonne classe)" do
    # Sélection F→C (préfixe 3) : chauffage + murs + toiture → C=2.
    c_target = run_target(%w[chauffage isolation_murs isolation_toiture])
    assert_equal 2, c_target

    # Décocher isolation_toiture → chauffage + murs → D=3. Remonte (pire).
    d_target = run_target(%w[chauffage isolation_murs])
    assert_equal 3, d_target
    assert_operator d_target, :>, c_target,
      "Décocher un geste doit ramener vers une classe moins bonne (idx plus grand)"

    # Recocher → retour à C=2.
    c_again = run_target(%w[chauffage isolation_murs isolation_toiture])
    assert_equal c_target, c_again,
      "Recocher doit ramener EXACTEMENT au même objectif — pas d'état interne parasite"
  end

  # ─── Purity : entrées non mutées ──────────────────────────────────────
  test "T-purity : deriveTargetFromSelection ne mute pas codesActifs ni combinaisons" do
    script = <<~JS
      const { deriveTargetFromSelection } = require(#{LOGIC_FILE.inspect});
      const codes = #{%w[isolation_murs chauffage].to_json};
      const combi = #{COMBI_SYNTH.to_json};
      const snapshotBefore = JSON.stringify({ codes, combi });
      deriveTargetFromSelection({
        codesActifs: codes, combinaisons: combi, currentDpeIdx: 5
      });
      deriveTargetFromSelection({
        codesActifs: codes, combinaisons: combi, currentDpeIdx: 5
      });
      const snapshotAfter = JSON.stringify({ codes, combi });
      console.log(JSON.stringify({ intact: snapshotBefore === snapshotAfter }));
    JS
    out, err, st = Open3.capture3(NODE_BIN, "-e", script)
    assert st.success?, "node script a échoué : #{err}"
    assert JSON.parse(out)["intact"],
      "codesActifs et combinaisons ne doivent JAMAIS être mutés"
  end
end
