require "test_helper"
require "open3"
require "json"

# Tests de la fonction PURE deriveSelection (app/javascript/dpe_slider_logic.js).
#
# Stratégie : exécuter le fichier JS via `node` en CLI depuis Minitest avec
# Open3, parser le JSON retourné, asserter en Ruby. Pas de runner JS dédié
# (Lauze n'en a pas), pas de bundler. La fonction est CommonJS (module.exports)
# pour Node ET déclarée comme fonction globale en script tag classique (cf.
# guard `if (typeof module ...)` en fin de fichier).
#
# Cas testés (cf. plan I/J/K/N) :
#   I — Bug menuiseries C→B : socle préservé, le geste fenêtres ne saute plus.
#   J — Monotonie : cible plus ambitieuse ⇒ checked ne rétrécit jamais.
#   K — Descente : peut retirer ce que la jauge avait ajouté, jamais le socle.
#   N — Pureté : entrées non mutées, idempotent.
#
# Si node n'est pas dans le PATH du runner de test, tous les tests sont skip
# avec un message clair (cf. setup).
class DpeSliderLogicTest < ActiveSupport::TestCase
  NODE_BIN   = "node".freeze
  LOGIC_FILE = Rails.root.join("app/javascript/dpe_slider_logic.js").to_s.freeze

  # Aligné avec show.html.erb:493-501 (DPE_IMPACT JS) et avec
  # TravauxMapperService::DPE_IMPACT côté Ruby. Si l'un des deux change, ce
  # test doit suivre.
  DPE_IMPACT = {
    "isolation_toiture"      => 1.0,
    "isolation_murs"         => 1.0,
    "isolation_plancher_bas" => 0.5,
    "chauffage"              => 1.5,
    "chauffe_eau"            => 0.5,
    "vmc"                    => 0.5,
    "menuiseries"            => 0.5
  }.freeze

  # Aligné avec TravauxMapperService::CANONICAL_CODES. L'ordre sert de
  # tie-breaker stable pour le tri par impact décroissant (cas typique :
  # 4 gestes d'impact 0.5 doivent garder cet ordre).
  CANONICAL_CODES = %w[
    isolation_toiture
    isolation_murs
    isolation_plancher_bas
    chauffage
    chauffe_eau
    vmc
    menuiseries
  ].freeze

  setup do
    out, err, st = Open3.capture3(NODE_BIN, "-v")
    skip "node CLI absent du PATH du runner de test (#{err.strip}). Installer node ou exporter PATH avant `bin/rails test`." unless st.success?
    @node_version = out.strip
  end

  # Helper : exécute deriveSelection(input) via node, retourne le hash parsé.
  # Le payload JSON arrive en process.argv[1] côté node — pattern stable et
  # qui évite tout problème d'échappement de quotes dans le script JS.
  def run_derive(input)
    payload = input.to_json
    script = <<~JS
      const { deriveSelection } = require(#{LOGIC_FILE.inspect});
      const input = JSON.parse(process.argv[1]);
      console.log(JSON.stringify(deriveSelection(input)));
    JS
    out, err, st = Open3.capture3(NODE_BIN, "-e", script, payload)
    raise "node failed (#{st.exitstatus}): #{err}" unless st.success?
    JSON.parse(out)
  end

  # ─── I. LE BUG ────────────────────────────────────────────────────────
  # Socle Claude de 5 gestes (apport DPE 4.5) incluant menuiseries. CUR=F.
  # Avant le fix : glisser C→B décochait menuiseries. Maintenant : le socle
  # couvre déjà le gain demandé (4.5 >= 4), donc la jauge ne touche RIEN.

  test "I — bug menuiseries C→B : socle inviolable, menuiseries reste cochée à C ET à B" do
    socle = %w[isolation_toiture isolation_murs chauffage vmc menuiseries]
    # Apport socle = 1.0 + 1.0 + 1.5 + 0.5 + 0.5 = 4.5

    # C : tgt=2, CUR=5 ⇒ gainSouhaite=3, socle apport=4.5 ⇒ socle suffit
    res_c = run_derive(
      currentDpeIdx: 5, targetIdx: 2,
      socle: socle, addedBySlider: [],
      dpeImpact: DPE_IMPACT, canonicalCodes: CANONICAL_CODES
    )

    # B : tgt=1, gainSouhaite=4, socle apport 4.5 ⇒ socle suffit toujours
    res_b = run_derive(
      currentDpeIdx: 5, targetIdx: 1,
      socle: socle, addedBySlider: [],
      dpeImpact: DPE_IMPACT, canonicalCodes: CANONICAL_CODES
    )

    # Menuiseries reste cochée DANS LES DEUX cas (cœur du bug).
    assert_includes res_c["checked"], "menuiseries",
                    "C : menuiseries doit rester cochée (socle inviolable)"
    assert_includes res_b["checked"], "menuiseries",
                    "B : menuiseries doit rester cochée — c'est exactement le bug : avant fix, C→B la décochait"

    # Socle ENTIER inclus dans les deux cas.
    assert_empty (socle - res_c["checked"]),
                 "C : tout le socle doit être coché. Manquants: #{(socle - res_c["checked"]).inspect}"
    assert_empty (socle - res_b["checked"]),
                 "B : tout le socle doit être coché — le bug retirait certains gestes en visant plus ambitieux"

    # Aucun ajout du slider tant que le socle couvre (idempotent stateless).
    assert_empty res_c["addedBySlider"],
                 "C : socle apport >= gainSouhaite ⇒ rien ajouté par la jauge"
    assert_empty res_b["addedBySlider"],
                 "B : socle apport >= gainSouhaite ⇒ rien ajouté par la jauge"
  end

  # ─── J. MONOTONIE ──────────────────────────────────────────────────────
  # Pour un socle faible (apport 1.5), monter la cible de F vers A doit
  # toujours faire grandir (ou stagner) `checked`. Le socle est inclus
  # à chaque cran.

  test "J — monotonie : cibles croissantes (F→…→A) ne rétrécissent jamais checked, socle toujours inclus" do
    socle = %w[chauffage] # apport 1.5
    cur   = 6             # CUR = G

    prev_checked = nil
    # Cibles de moins ambitieuse (F=5) à plus ambitieuse (A=0).
    [5, 4, 3, 2, 1, 0].each do |tgt|
      res = run_derive(
        currentDpeIdx: cur, targetIdx: tgt,
        socle: socle, addedBySlider: [],
        dpeImpact: DPE_IMPACT, canonicalCodes: CANONICAL_CODES
      )
      checked = res["checked"]

      # Socle inclus à chaque cran.
      assert_empty (socle - checked),
                   "tgt=#{tgt} : socle doit rester inclus. Manquants: #{(socle - checked).inspect}"

      # Monotonie : nouveau checked ⊇ ancien checked.
      if prev_checked
        manquants = prev_checked - checked
        assert_empty manquants,
                     "tgt=#{tgt} : rétrécissement détecté en montant la cible. Gestes perdus: #{manquants.inspect}. " \
                     "Avant: #{prev_checked.inspect}. Maintenant: #{checked.inspect}"
      end

      prev_checked = checked
    end
  end

  # ─── K. DESCENTE ───────────────────────────────────────────────────────
  # Aller à A puis redescendre à D : on PEUT retirer des ajouts de la jauge,
  # mais le socle reste intouché. Les retraits doivent tous être des codes
  # qui étaient dans addedBySlider à A.

  test "K — descente A→D : peut retirer ce que la jauge a ajouté, JAMAIS le socle" do
    socle = %w[chauffage] # apport 1.5
    cur   = 6

    # Montée à A : la jauge ajoute beaucoup.
    res_a = run_derive(
      currentDpeIdx: cur, targetIdx: 0,
      socle: socle, addedBySlider: [],
      dpeImpact: DPE_IMPACT, canonicalCodes: CANONICAL_CODES
    )

    # Sanity : à A, des ajouts ont bien été faits.
    refute_empty res_a["addedBySlider"], "Sanity : à A, la jauge doit avoir ajouté"

    # Redescente à D : tgt=3, gainSouhaite=3 ; apport socle 1.5 ⇒ reste 1.5
    res_d = run_derive(
      currentDpeIdx: cur, targetIdx: 3,
      socle: socle,
      addedBySlider: res_a["addedBySlider"],
      dpeImpact: DPE_IMPACT, canonicalCodes: CANONICAL_CODES
    )

    # Socle toujours là.
    assert_empty (socle - res_d["checked"]),
                 "Descente : socle doit rester inclus. Manquants: #{(socle - res_d["checked"]).inspect}"

    # checked à D ⊆ checked à A (on est descendu, on a moins ou égal).
    extras = res_d["checked"] - res_a["checked"]
    assert_empty extras,
                 "Descente : checked à D doit être un sous-ensemble de A. Extras: #{extras.inspect}"

    # CHAQUE retrait (A \ D) doit être un code qui était dans addedBySlider à A
    # ET ne doit JAMAIS être dans le socle.
    retraits = res_a["checked"] - res_d["checked"]
    refute_empty retraits, "Sanity : descendre A→D doit retirer au moins un geste"
    retraits.each do |code|
      assert_includes res_a["addedBySlider"], code,
                      "Retrait '#{code}' : doit avoir été ajouté par la jauge (présent dans addedBySlider précédent)"
      refute_includes socle, code,
                      "Retrait '#{code}' : NE DOIT PAS être dans le socle"
    end
  end

  # ─── N. PURETÉ ─────────────────────────────────────────────────────────
  # Vérifie :
  #   a) idempotence — deux appels avec mêmes entrées ⇒ mêmes sorties
  #   b) non-mutation — les arrays/objets passés en entrée ne sont pas modifiés
  # On fait LE TEST EN UN SEUL APPEL NODE pour observer la mutation potentielle
  # côté process JS (Node CLI redémarre à chaque Open3, donc 2 calls Open3
  # masqueraient une mutation interne).

  test "N — pureté : idempotent, n'altère pas les arrays/objets passés en entrée" do
    script = <<~JS
      const { deriveSelection } = require(#{LOGIC_FILE.inspect});
      const socle      = ['chauffage', 'isolation_toiture'];
      const added      = ['isolation_murs'];
      const dpeImpact  = #{DPE_IMPACT.to_json};
      const canonical  = #{CANONICAL_CODES.to_json};

      // Snapshot AVANT
      const snapshotBefore = JSON.stringify({ socle, added, dpeImpact, canonical });

      // Deux appels successifs avec les MÊMES références.
      const input = {
        currentDpeIdx: 5, targetIdx: 1,
        socle, addedBySlider: added,
        dpeImpact, canonicalCodes: canonical
      };
      const res1 = deriveSelection(input);
      const res2 = deriveSelection(input);

      // Snapshot APRÈS
      const snapshotAfter = JSON.stringify({ socle, added, dpeImpact, canonical });

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
           "Idempotence : deux appels avec les mêmes entrées doivent retourner exactement la même chose. " \
           "res1=#{data["res1"].inspect}, res2=#{data["res2"].inspect}"
    assert data["inputsIntact"],
           "Non-mutation : les arrays/objets passés en entrée ne doivent pas être modifiés. " \
           "Avant: #{data["before"]}, Après: #{data["after"]}"
  end
end
