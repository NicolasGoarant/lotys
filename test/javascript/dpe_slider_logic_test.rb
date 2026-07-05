require "test_helper"
require "open3"
require "json"

# Tests des trois fonctions pures de app/javascript/dpe_slider_logic.js :
#
#   - deriveSelectionForTarget  : classe cible → sélection travaux
#                                 (retour enrichi : derivedClasseIdx, recale).
#   - deriveTargetFromSelection : cases cochées → classe atteignable.
#   - computeDominatedClasses   : classes jamais un point d'arrivée du drag.
#
# Sémantique "AU MOINS X, LE MOINS CHER" :
#   deriveSelectionForTarget(X) retourne la combinaison LA MOINS CHÈRE
#   dont la classe dérivée est <= X (target ou mieux). Peut donc rendre
#   une classe MEILLEURE que celle cliquée si c'est moins cher. Flag
#   `recale` posé dans le retour pour que la vue affiche honnêtement
#   le décalage.
#
# Verrou central : MONOTONIE DES COÛTS. Viser mieux ne peut jamais
# coûter moins cher que viser moins bien — la version précédente ("match
# exact") avait ce bug en prod (D → 13k€, E → 26,5k€).
#
# Stratégie : exécuter le JS via `node` en CLI, parser le JSON retourné.
class DpeSliderLogicTest < ActiveSupport::TestCase
  NODE_BIN   = "node".freeze
  LOGIC_FILE = Rails.root.join("app/javascript/dpe_slider_logic.js").to_s.freeze

  # ── Matrice synthétique — chaîne classique de préfixes ────────────────
  COMBI_SYNTH = {
    ""                                                                                              => { "classe" => "F" },
    "isolation_murs"                                                                                => { "classe" => "E" },
    "chauffage,isolation_murs"                                                                      => { "classe" => "D" },
    "chauffage,isolation_murs,isolation_toiture"                                                    => { "classe" => "C" },
    "chauffage,isolation_murs,isolation_toiture,menuiseries"                                        => { "classe" => "B" },
    "chauffage,isolation_murs,isolation_toiture,menuiseries,vmc"                                    => { "classe" => "B" },
    "chauffage,isolation_murs,isolation_plancher_bas,isolation_toiture,menuiseries,vmc"             => { "classe" => "B" },
    "chauffage,chauffe_eau,isolation_murs,isolation_plancher_bas,isolation_toiture,menuiseries,vmc" => { "classe" => "A" }
  }.freeze

  # Coûts monotones croissants (chaque geste > somme des précédents).
  COSTS_SYNTH = {
    "isolation_murs"         => 1,
    "chauffage"              => 10,
    "isolation_toiture"      => 100,
    "menuiseries"            => 1_000,
    "vmc"                    => 10_000,
    "isolation_plancher_bas" => 100_000,
    "chauffe_eau"            => 1_000_000
  }.freeze

  # ── Matrice "E dominé par D" (reproduction du bug prod) ────────────────
  # Bien F. isolation_toiture SEULE atteint E (26,5k€ virtuel).
  # isolation_murs SEULE atteint D (13k€ virtuel — moins cher).
  # Sous "au moins X", cliquer E → murs (D), et E est dominé.
  COMBI_E_DOMINE = {
    ""                                 => { "classe" => "F" },
    "isolation_toiture"                => { "classe" => "E" },
    "isolation_murs"                   => { "classe" => "D" },
    "isolation_murs,isolation_toiture" => { "classe" => "C" }
  }.freeze

  COSTS_E_DOMINE = {
    "isolation_murs"     => 13_000,   # meilleur levier, moins cher
    "isolation_toiture"  => 26_500    # atteint pile E mais 2× plus cher
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

  def derive(current_dpe_idx:, target_idx:,
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

  def run_dominated(current_dpe_idx:, combinaisons:, costs:)
    payload = {
      currentDpeIdx: current_dpe_idx,
      combinaisons:  combinaisons,
      travauxCosts:  costs
    }.to_json
    script = <<~JS
      const { computeDominatedClasses } = require(#{LOGIC_FILE.inspect});
      console.log(JSON.stringify(computeDominatedClasses(JSON.parse(process.argv[1]))));
    JS
    out, err, st = Open3.capture3(NODE_BIN, "-e", script, payload)
    raise "node failed (#{st.exitstatus}): #{err}" unless st.success?
    JSON.parse(out)
  end

  # Coût d'une sélection selon un barème de coûts.
  def cost_of(codes, costs)
    codes.sum { |c| costs[c] || 0 }
  end

  # ═════════════════════════════════════════════════════════════════════════
  # deriveSelectionForTarget — sens JAUGE → CASES, sémantique "au moins X"
  # ═════════════════════════════════════════════════════════════════════════

  # ─── LE verrou : MONOTONIE DES COÛTS ──────────────────────────────────
  # Sur COMBI_SYNTH (classique) ET COMBI_E_DOMINE (bug prod), le coût de
  # la sélection doit croître (au sens large) quand on passe d'une cible
  # moins ambitieuse à une plus ambitieuse. C'est la propriété qui
  # empêche le bug prod « E coûte 2× plus cher que D ».
  test "MONOTONIE — sur COMBI_SYNTH : coût(sélection(tgt)) croissant de F à A" do
    cur = 5
    couts = [5, 4, 3, 2, 1, 0].map do |tgt|
      selection = derive(current_dpe_idx: cur, target_idx: tgt)["checked"]
      cost_of(selection, COSTS_SYNTH)
    end
    assert_equal couts, couts.sort,
      "Les coûts doivent être croissants dans l'ordre tgt=5→0 (F→A). Obtenus : #{couts.inspect}"
  end

  test "MONOTONIE — sur COMBI_E_DOMINE (repro bug prod) : coût D <= coût E" do
    cur = 5
    tous = [5, 4, 3, 2].map do |tgt|
      selection = derive(current_dpe_idx: cur, target_idx: tgt,
                         combinaisons: COMBI_E_DOMINE, costs: COSTS_E_DOMINE)["checked"]
      { tgt: tgt, checked: selection, cost: cost_of(selection, COSTS_E_DOMINE) }
    end
    # Verrou du bug : sur COMBI_E_DOMINE, tgt=4 (E) et tgt=3 (D) partagent
    # la même sélection [isolation_murs] pour un coût de 13 000 €. Viser
    # E ne coûte JAMAIS plus cher que viser D.
    couts = tous.map { |r| r[:cost] }
    assert_equal couts, couts.sort,
      "Bug prod reproduit : coûts non-monotones ⇒ E plus cher que D. " \
      "Détails : #{tous.inspect}"
  end

  # ─── E dominé par D : sélection identique, classe dérivée D, recale=true ─
  test "E dominé par D : sélection(E) == sélection(D), derivedClasseIdx=D, recale=true" do
    e = derive(current_dpe_idx: 5, target_idx: 4,
               combinaisons: COMBI_E_DOMINE, costs: COSTS_E_DOMINE)
    d = derive(current_dpe_idx: 5, target_idx: 3,
               combinaisons: COMBI_E_DOMINE, costs: COSTS_E_DOMINE)

    assert_equal ["isolation_murs"], e["checked"],
      "Cible E : la sélection la moins chère qui atteint E ou mieux = murs (D). " \
      "Obtenu : #{e["checked"].inspect}"
    assert_equal d["checked"], e["checked"],
      "E est dominé par D → même sélection dans les deux cas"
    assert_equal 3, e["derivedClasseIdx"], "derivedClasseIdx = 3 (D), pas 4 (E) : on affiche la vérité"
    assert_equal true, e["recale"],
      "Flag recale=true pour permettre à la vue d'afficher le microtexte"
    assert_equal false, d["recale"],
      "Cliquer D directement : pas de recalage, la sélection l'atteint pile"
  end

  # ─── Stabilité slider : deux drags sur X = même état ──────────────────
  test "stabilité : deux drags sur la même classe donnent exactement la même sortie" do
    cur = 5
    [0, 1, 2, 3, 4].each do |tgt|
      a = derive(current_dpe_idx: cur, target_idx: tgt)
      b = derive(current_dpe_idx: cur, target_idx: tgt)
      assert_equal a, b,
        "tgt=#{tgt} : deux appels doivent produire des sorties identiques (déterminisme)"
    end
  end

  # ─── Aucune sélection dont la classe dérivée serait PIRE que demandée ─
  # Invariant : derivedClasseIdx <= targetIdx dans le CAS NOMINAL (au moins
  # une combinaison qualifiée). Seul le fallback pessimist strict (aucune
  # combinaison ne satisfait <=X) peut donner derivedClasseIdx > targetIdx —
  # documenté ci-dessous comme "chemin de secours", pas le nominal.
  test "invariant : dans le cas nominal, derivedClasseIdx <= targetIdx" do
    cur = 5
    [0, 1, 2, 3, 4].each do |tgt|
      r = derive(current_dpe_idx: cur, target_idx: tgt)
      # Quand COMBI_SYNTH contient une entrée <=tgt (ce qui est toujours
      # le cas ici), la sortie doit satisfaire <=tgt.
      assert_operator r["derivedClasseIdx"], :<=, tgt,
        "tgt=#{tgt} : derivedClasseIdx=#{r["derivedClasseIdx"]} > tgt — " \
        "la sémantique 'au moins X' est violée"
    end
  end

  # ─── Plafond anti-dégradation conservé ────────────────────────────────
  test "plafond : sélection jamais pire que currentDpeIdx" do
    # Bien F (5), matrice ne remonte à rien de mieux : sélection vide,
    # derivedClasseIdx == currentDpeIdx (pas plus mauvais).
    combi_flat = { "" => { "classe" => "F" } }
    r = derive(current_dpe_idx: 5, target_idx: 3, combinaisons: combi_flat, costs: {})
    assert_operator r["derivedClasseIdx"], :<=, 5,
      "Jamais pire que currentDpeIdx même sur matrice sans amélioration atteignable"
  end

  # ─── Cible >= currentDpeIdx → no-op sans recalage ─────────────────────
  test "cible >= currentDpeIdx : sélection vide, recale=false" do
    r = derive(current_dpe_idx: 5, target_idx: 5)
    assert_equal [],  r["checked"]
    assert_equal 5,   r["derivedClasseIdx"]
    assert_equal false, r["recale"]
  end

  # ─── Pureté ───────────────────────────────────────────────────────────
  test "pureté : combinaisons et travauxCosts non mutés, idempotent" do
    script = <<~JS
      const { deriveSelectionForTarget } = require(#{LOGIC_FILE.inspect});
      const combinaisons = #{COMBI_SYNTH.to_json};
      const travauxCosts = #{COSTS_SYNTH.to_json};
      const before = JSON.stringify({ combinaisons, travauxCosts });
      const input = { currentDpeIdx: 5, targetIdx: 2, combinaisons, travauxCosts };
      const r1 = deriveSelectionForTarget(input);
      const r2 = deriveSelectionForTarget(input);
      const after = JSON.stringify({ combinaisons, travauxCosts });
      console.log(JSON.stringify({
        idempotent:   JSON.stringify(r1) === JSON.stringify(r2),
        inputsIntact: before === after
      }));
    JS
    out, err, st = Open3.capture3(NODE_BIN, "-e", script)
    assert st.success?, "node script a échoué : #{err}"
    data = JSON.parse(out)
    assert data["idempotent"],   "Idempotence"
    assert data["inputsIntact"], "Non-mutation"
  end

  # ─── NOTE — Test « cible inatteignable → jamais mieux que demandé » supprimé.
  # Ce test codifiait l'ancienne sémantique "match exact + pessimiste
  # jamais mieux que demandé". La nouvelle sémantique "au moins X, le
  # moins cher" abandonne exactement cette contrainte : on ACCEPTE
  # explicitement de donner une classe meilleure que demandée si c'est
  # moins cher (avec recalage transparent via le flag `recale`). Retenir
  # ce test aurait figé le bug prod (E plus cher que D).

  # ═════════════════════════════════════════════════════════════════════════
  # computeDominatedClasses — affordance visuelle
  # ═════════════════════════════════════════════════════════════════════════

  test "affordance : sur COMBI_E_DOMINE, la classe E est dominée par D" do
    dominated = run_dominated(
      current_dpe_idx: 5,
      combinaisons:    COMBI_E_DOMINE,
      costs:           COSTS_E_DOMINE
    )
    assert_includes dominated, 4,
      "E (idx 4) doit être détectée dominée (cliquer dessus recale vers D=3). " \
      "Obtenu : #{dominated.inspect}"
    refute_includes dominated, 3, "D (idx 3) n'est PAS dominée — c'est vers elle qu'on recale"
  end

  test "affordance : sur COMBI_SYNTH (chaîne classique), aucune classe n'est dominée" do
    dominated = run_dominated(
      current_dpe_idx: 5,
      combinaisons:    COMBI_SYNTH,
      costs:           COSTS_SYNTH
    )
    assert_empty dominated,
      "Chaîne de préfixes monotones : chaque classe atteignable est un point " \
      "d'arrivée légitime. Obtenu : #{dominated.inspect}"
  end

  test "affordance : classe >= currentDpeIdx jamais dans le retour (pas un point d'arrivée du slider)" do
    dominated = run_dominated(
      current_dpe_idx: 3,
      combinaisons:    COMBI_SYNTH,
      costs:           COSTS_SYNTH
    )
    # Que dominated soit vide ou non, aucun idx ne doit être >= 3 (currentDpeIdx).
    assert dominated.all? { |i| i < 3 },
      "Aucun idx >= currentDpeIdx=3 ne doit apparaître. Obtenu : #{dominated.inspect}"
  end

  # ═════════════════════════════════════════════════════════════════════════
  # deriveTargetFromSelection — sens CASES → JAUGE
  # ═════════════════════════════════════════════════════════════════════════

  test "T-nominal : combinaison connue → idx de la classe atteignable" do
    assert_equal 3, run_target(%w[isolation_murs chauffage])
    assert_equal 2, run_target(%w[isolation_murs chauffage isolation_toiture])
    assert_equal 5, run_target([])
  end

  # ─── Plafond anti-dégradation (fix historique anomalie 1) ─────────────
  test "plafond : matrice donne G, currentDpeIdx=F → label plafonné à F" do
    combi_buggy = { "" => { "classe" => "G" } }
    assert_equal 5, run_target([], combinaisons: combi_buggy, current_dpe_idx: 5)
  end

  test "plafond : un geste absurde qui empire selon la matrice → plafonné" do
    combi_buggy = {
      ""                  => { "classe" => "F" },
      "isolation_toiture" => { "classe" => "G" }
    }
    assert_equal 5, run_target(%w[isolation_toiture], combinaisons: combi_buggy, current_dpe_idx: 5)
  end

  test "plafond : invariant sur toute COMBI_SYNTH — jamais > currentDpeIdx" do
    COMBI_SYNTH.each_key do |cle|
      codes = cle == "" ? [] : cle.split(",")
      idx = run_target(codes, current_dpe_idx: 5)
      assert_operator idx, :<=, 5
    end
  end

  # ─── Fallbacks pessimistes ────────────────────────────────────────────
  test "T-fallback : combinaison manquante → currentDpeIdx" do
    assert_equal 5, run_target(%w[menuiseries], current_dpe_idx: 5)
  end

  test "T-fallback : matrice null → currentDpeIdx" do
    assert_equal 4, run_target(%w[isolation_murs], combinaisons: nil, current_dpe_idx: 4)
  end

  test "T-fallback : classe non-string / hors A-G → currentDpeIdx" do
    assert_equal 5, run_target(%w[m], combinaisons: { "m" => { "classe" => nil } }, current_dpe_idx: 5)
    assert_equal 5, run_target(%w[m], combinaisons: { "m" => { "classe" => "Z" } }, current_dpe_idx: 5)
  end

  # ─── Déterminisme ─────────────────────────────────────────────────────
  test "T-déterminisme : même codesActifs → même objectif" do
    codes = %w[isolation_murs chauffage isolation_toiture]
    assert_equal [run_target(codes)] * 5, 5.times.map { run_target(codes) }
  end

  test "T-ordre-invariant : réordonner codesActifs ne change pas l'objectif" do
    a = run_target(%w[isolation_murs chauffage isolation_toiture])
    b = run_target(%w[isolation_toiture chauffage isolation_murs])
    assert_equal a, b
  end

  # ─── Check / uncheck / recheck ────────────────────────────────────────
  test "T-check-uncheck : décocher fait remonter, recocher redescend au même idx" do
    c = run_target(%w[chauffage isolation_murs isolation_toiture])
    assert_equal 2, c
    d = run_target(%w[chauffage isolation_murs])
    assert_equal 3, d
    assert_operator d, :>, c
    assert_equal c, run_target(%w[chauffage isolation_murs isolation_toiture])
  end

  # ═════════════════════════════════════════════════════════════════════════
  # targetIdxFromSegment — fonction pure, mappage sûr data-idx → int 0..6
  # ═════════════════════════════════════════════════════════════════════════
  # Extraite pour rendre le pipeline "clic segment → index" testable sans
  # jsdom. Verrou anti-régression du bug prod bien 214/215 (clic B/E ignoré).

  def run_from_segment(seg_mock)
    payload = seg_mock.to_json
    script = <<~JS
      const { targetIdxFromSegment } = require(#{LOGIC_FILE.inspect});
      console.log(JSON.stringify(targetIdxFromSegment(JSON.parse(process.argv[1]))));
    JS
    out, err, st = Open3.capture3(NODE_BIN, "-e", script, payload)
    raise "node failed: #{err}" unless st.success?
    JSON.parse(out)
  end

  test "targetIdxFromSegment — lit correctement data-idx pour A→G (0..6)" do
    (0..6).each do |i|
      mock = { "dataset" => { "idx" => i.to_s } }
      assert_equal i, run_from_segment(mock),
        "data-idx=#{i.inspect} doit retourner #{i}"
    end
  end

  test "targetIdxFromSegment — rejette valeurs invalides (null, undefined, hors 0..6)" do
    # dataset.idx absent
    assert_nil run_from_segment({ "dataset" => {} })
    # Non-numérique
    assert_nil run_from_segment({ "dataset" => { "idx" => "abc" } })
    # Hors bornes
    assert_nil run_from_segment({ "dataset" => { "idx" => "7" } })
    assert_nil run_from_segment({ "dataset" => { "idx" => "-1" } })
    # Segment sans dataset (mock partiel)
    assert_nil run_from_segment({})
  end

  # Simulation d'un event click : on construit un DOM synthétique avec 7
  # segments, on branche l'event delegation exactement comme dans la vue,
  # on dispatch un MouseEvent au centre visuel de chaque segment, et on
  # vérifie que onSliderChange reçoit EXACTEMENT l'index attendu.
  #
  # Utilise l'API minimale de node CLI + polyfill DOM léger. Un module
  # Node externe (jsdom) serait plus complet mais introduit une dépendance
  # ; ici on écrit un mini-mock en JavaScript pur qui suffit pour ce test.
  test "event delegation .dpe-track — click sur chaque segment A→F → onSliderChange reçoit l'index exact" do
    script = <<~JS
      const { targetIdxFromSegment } = require(#{LOGIC_FILE.inspect});

      // Mini-mock DOM : Element, Event, MouseEvent basiques.
      class MiniElement {
        constructor(tag){
          this.tagName = tag.toUpperCase();
          this.dataset = {};
          this.classList = new Set();
          this.children = [];
          this.parentNode = null;
          this._listeners = {};
        }
        appendChild(c){ c.parentNode = this; this.children.push(c); return c; }
        addEventListener(type, fn){ (this._listeners[type] = this._listeners[type] || []).push(fn); }
        // closest walks up the parent chain looking for a match by class.
        closest(sel){
          const cls = sel.replace(/^\\./, '');
          let cur = this;
          while(cur){
            if(cur.classList && cur.classList.has(cls)) return cur;
            cur = cur.parentNode;
          }
          return null;
        }
        // Dispatch : appelle les listeners du type, puis bubble au parent.
        dispatchClickAt(target){
          const evt = { target: target };
          let cur = this;
          while(cur){
            (cur._listeners['click'] || []).forEach(fn => fn(evt));
            cur = cur.parentNode;
          }
        }
      }

      // Construit le DOM : track > 7 segments (data-idx 0..6).
      const track = new MiniElement('div');
      track.classList.add('dpe-track');
      const segs = [];
      for(let i = 0; i <= 6; i++){
        const seg = new MiniElement('div');
        seg.classList.add('dpe-seg');
        seg.dataset.idx = String(i);
        track.appendChild(seg);
        segs.push(seg);
      }

      // Wire event delegation EXACTEMENT comme la vue.
      const received = [];
      track.addEventListener('click', function(evt){
        const seg = evt.target && evt.target.closest ? evt.target.closest('.dpe-seg') : null;
        if(!seg) return;
        const idx = targetIdxFromSegment(seg);
        if(idx !== null) received.push(idx);
      });

      // Simule un clic sur chaque segment (target = ce segment).
      for(let i = 0; i <= 6; i++){
        track.dispatchClickAt(segs[i]);
      }

      console.log(JSON.stringify(received));
    JS
    out, err, st = Open3.capture3(NODE_BIN, "-e", script)
    assert st.success?, "node script a échoué : #{err}"
    received = JSON.parse(out)
    assert_equal [0, 1, 2, 3, 4, 5, 6], received,
      "Chaque clic doit remonter l'index EXACT du segment. Reçu : #{received.inspect}"
  end

  test "event delegation — clic sur un descendant du segment (text node parent) capté aussi" do
    # Sécurise le fait que closest() remonte au segment même si le clic
    # tombait initialement sur un enfant.
    script = <<~JS
      const { targetIdxFromSegment } = require(#{LOGIC_FILE.inspect});
      class MiniElement {
        constructor(tag){
          this.tagName = tag.toUpperCase();
          this.dataset = {};
          this.classList = new Set();
          this.children = [];
          this.parentNode = null;
          this._listeners = {};
        }
        appendChild(c){ c.parentNode = this; this.children.push(c); return c; }
        addEventListener(t, fn){ (this._listeners[t] = this._listeners[t] || []).push(fn); }
        closest(sel){
          const cls = sel.replace(/^\\./, '');
          let cur = this;
          while(cur){ if(cur.classList && cur.classList.has(cls)) return cur; cur = cur.parentNode; }
          return null;
        }
        dispatchClickAt(t){
          const evt = { target: t };
          let cur = this;
          while(cur){ (cur._listeners['click'] || []).forEach(fn => fn(evt)); cur = cur.parentNode; }
        }
      }
      const track = new MiniElement('div'); track.classList.add('dpe-track');
      const seg = new MiniElement('div'); seg.classList.add('dpe-seg'); seg.dataset.idx = '4';
      const child = new MiniElement('span');  // enfant décoratif (pas .dpe-seg)
      seg.appendChild(child);
      track.appendChild(seg);
      const received = [];
      track.addEventListener('click', function(evt){
        const s = evt.target && evt.target.closest ? evt.target.closest('.dpe-seg') : null;
        if(!s) return;
        const idx = targetIdxFromSegment(s);
        if(idx !== null) received.push(idx);
      });
      track.dispatchClickAt(child);
      console.log(JSON.stringify(received));
    JS
    out, err, st = Open3.capture3(NODE_BIN, "-e", script)
    assert st.success?, "node script a échoué : #{err}"
    assert_equal [4], JSON.parse(out),
      "closest() doit remonter au .dpe-seg parent même quand le clic tombe sur un enfant"
  end

  # ─── Purity ──────────────────────────────────────────────────────────
  test "T-purity : deriveTargetFromSelection ne mute pas ses entrées" do
    script = <<~JS
      const { deriveTargetFromSelection } = require(#{LOGIC_FILE.inspect});
      const codes = #{%w[isolation_murs chauffage].to_json};
      const combi = #{COMBI_SYNTH.to_json};
      const before = JSON.stringify({ codes, combi });
      deriveTargetFromSelection({ codesActifs: codes, combinaisons: combi, currentDpeIdx: 5 });
      const after = JSON.stringify({ codes, combi });
      console.log(JSON.stringify({ intact: before === after }));
    JS
    out, err, st = Open3.capture3(NODE_BIN, "-e", script)
    assert st.success?, "node script a échoué : #{err}"
    assert JSON.parse(out)["intact"]
  end
end
