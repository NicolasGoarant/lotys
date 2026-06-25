require "test_helper"
require "open3"
require "json"

# Tests de la fonction PURE deriveSelectionForTarget
# (app/javascript/dpe_slider_logic.js).
#
# Modèle CASCADE MONOTONE :
#   - Une cible (lettre DPE) → une sélection FIXE, chemin-indépendante.
#   - La sélection est un PRÉFIXE d'une file canonique (impact décroissant
#     + tie-break canonicalCodes stable).
#   - Cibles plus ambitieuses ⇒ préfixes plus longs ⇒ sur-ensembles emboîtés.
#
# Stratégie : exécuter le fichier JS via `node` en CLI depuis Minitest avec
# Open3, parser le JSON retourné, asserter en Ruby. Pas de runner JS (Lauze
# n'en a pas), pas de bundler. La fonction est CommonJS pour Node ET déclarée
# comme fonction globale en script tag classique.
#
# Cas testés :
#   P — Chemin-indépendance : deux appels avec même targetIdx ⇒ sélections
#       identiques. Formalise le bug "B donne 3 sélections différentes
#       selon le chemin des drags" (vu en prod sur d1ac5b5/v101).
#   Q — Cascade monotone : pour toute la chaîne G→…→A, sélection(tgt-1) ⊇
#       sélection(tgt). Monter n'enlève jamais rien, c'est garanti par
#       l'algorithme (préfixes emboîtés), pas par condition.
#   I — Menuiseries : non exclue arbitrairement. Sur une cible assez
#       ambitieuse pour exiger la fin de la file, menuiseries EST cochée.
#       Et son inclusion est STABLE (toujours pareil, pas "parfois").
#   N — Pureté : entrées non mutées, idempotent.
#
# Si node n'est pas dans le PATH du runner, tous les tests sont skip avec un
# message clair (cf. setup).
class DpeSliderLogicTest < ActiveSupport::TestCase
  NODE_BIN   = "node".freeze
  LOGIC_FILE = Rails.root.join("app/javascript/dpe_slider_logic.js").to_s.freeze

  # Aligné avec show.html.erb (DPE_IMPACT JS) et TravauxMapperService::DPE_IMPACT.
  DPE_IMPACT = {
    "isolation_toiture"      => 1.0,
    "isolation_murs"         => 1.0,
    "isolation_plancher_bas" => 0.5,
    "chauffage"              => 1.5,
    "chauffe_eau"            => 0.5,
    "vmc"                    => 0.5,
    "menuiseries"            => 0.5
  }.freeze

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

  # Helper : exécute deriveSelectionForTarget(input) via node, retourne le
  # hash parsé. Le payload JSON arrive en process.argv[1] côté node — pattern
  # stable qui évite tout échappement de quotes dans le script.
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

  # ─── P. CHEMIN-INDÉPENDANCE ──────────────────────────────────────────
  # LE test qui formalise le bug observé en prod : 3 captures sur cible B
  # donnaient 3 sélections + 3 budgets différents parce que la fonction
  # précédente prenait `currentlyChecked` en entrée. Ici on n'a plus
  # d'entrée d'historique — la propriété est garantie par signature.
  # On l'asserte explicitement pour la formaliser.

  test "P — chemin-indépendance : pour une cible donnée, deux appels retournent exactement la même sélection" do
    cur = 5 # F

    # Cible B (idx 1), gain 4. On appelle deux fois — pas d'historique
    # à passer, donc la sortie ne peut dépendre de rien d'autre que des
    # arguments explicites.
    res_b_1 = run_derive(
      currentDpeIdx: cur, targetIdx: 1,
      dpeImpact: DPE_IMPACT, canonicalCodes: CANONICAL_CODES
    )
    res_b_2 = run_derive(
      currentDpeIdx: cur, targetIdx: 1,
      dpeImpact: DPE_IMPACT, canonicalCodes: CANONICAL_CODES
    )
    assert_equal res_b_1["checked"].sort, res_b_2["checked"].sort,
                 "Deux appels avec mêmes args ⇒ même sélection. " \
                 "(Si rouge, la fonction a réintroduit une dépendance cachée — variable globale, " \
                 "horloge, Math.random, etc. — qui violerait le déterminisme.)"

    # Et pour insister : toutes les cibles donnent des résultats stables.
    [5, 4, 3, 2, 1, 0].each do |tgt|
      a = run_derive(currentDpeIdx: cur, targetIdx: tgt, dpeImpact: DPE_IMPACT, canonicalCodes: CANONICAL_CODES)
      b = run_derive(currentDpeIdx: cur, targetIdx: tgt, dpeImpact: DPE_IMPACT, canonicalCodes: CANONICAL_CODES)
      assert_equal a["checked"].sort, b["checked"].sort,
                   "tgt=#{tgt} : sélections doivent être identiques entre deux appels"
    end
  end

  # ─── Q. CASCADE MONOTONE EMBOÎTÉE ────────────────────────────────────
  # Pour toutes les paires (tgt, tgt-1) avec tgt-1 plus ambitieuse :
  # sélection(tgt-1) ⊇ sélection(tgt). On vérifie sur toute la chaîne.

  test "Q — cascade monotone : sur toute la chaîne G→A, chaque cible plus ambitieuse est un sur-ensemble de la moins ambitieuse" do
    cur = 6 # G : permet d'explorer toute la gamme de gains 0→6

    # Cibles de la moins ambitieuse (G=6, gain 0) à la plus ambitieuse (A=0, gain 6).
    cibles = [6, 5, 4, 3, 2, 1, 0]
    selections = cibles.map do |tgt|
      run_derive(currentDpeIdx: cur, targetIdx: tgt, dpeImpact: DPE_IMPACT, canonicalCodes: CANONICAL_CODES)["checked"]
    end

    # Pour chaque cran : la cible suivante (plus ambitieuse) doit être un
    # sur-ensemble de la précédente.
    cibles.each_with_index do |tgt, i|
      next if i == 0
      moins_ambitieuse = selections[i - 1]
      plus_ambitieuse  = selections[i]
      perdus = moins_ambitieuse - plus_ambitieuse
      assert_empty perdus,
                   "Passer de tgt=#{cibles[i - 1]} à tgt=#{tgt} (plus ambitieuse) " \
                   "ne doit jamais perdre de geste. Perdus: #{perdus.inspect}. " \
                   "moins_ambitieuse=#{moins_ambitieuse.inspect}, plus_ambitieuse=#{plus_ambitieuse.inspect}"
    end

    # Et par construction (préfixes), chaque sélection plus ambitieuse doit
    # être au moins aussi grande que la précédente.
    cibles.each_with_index do |_tgt, i|
      next if i == 0
      assert_operator selections[i].size, :>=, selections[i - 1].size,
                      "|sélection(tgt=#{cibles[i]})| doit être ≥ |sélection(tgt=#{cibles[i - 1]})|"
    end
  end

  # ─── I. Menuiseries — inclusion stable, pas arbitraire ───────────────
  # Avec dpeImpact actuel, menuiseries est en QUEUE de la file canonique.
  # Elle n'est cochée que pour les cibles très ambitieuses. Ce test acte
  # ce comportement : pour gain = 6 (G→A), menuiseries est cochée. Et son
  # inclusion est STABLE — pas "parfois", toujours.

  test "I — menuiseries : sur cible très ambitieuse (G→A, gain 6), menuiseries EST cochée, et son inclusion est stable" do
    cur = 6 # G

    # Cible A (idx 0), gain 6. La file totale a un cumul max de 4.5
    # (1.5+1.0+1.0+0.5+0.5+0.5+0.5 = 5.5). Gain 6 > 5.5 ⇒ on coche TOUT.
    res = run_derive(
      currentDpeIdx: cur, targetIdx: 0,
      dpeImpact: DPE_IMPACT, canonicalCodes: CANONICAL_CODES
    )
    assert_includes res["checked"], "menuiseries",
                    "G→A (gain 6 > cumul max 5.5) : toutes les cases doivent être cochées, dont menuiseries. " \
                    "checked=#{res["checked"].inspect}"

    # Stabilité : 5 appels successifs, toujours pareil.
    5.times do |i|
      r = run_derive(currentDpeIdx: cur, targetIdx: 0, dpeImpact: DPE_IMPACT, canonicalCodes: CANONICAL_CODES)
      assert_includes r["checked"], "menuiseries",
                      "Appel ##{i + 1} : menuiseries doit toujours être cochée à G→A"
    end
  end

  # ─── N. PURETÉ ────────────────────────────────────────────────────────
  # Idempotent + entrées non mutées. Test scripté en UN SEUL process Node
  # (deux Open3 successifs masqueraient une mutation interne — Node redémarre
  # à chaque appel CLI).

  test "N — pureté : idempotent, n'altère pas les arrays/objets passés en entrée" do
    script = <<~JS
      const { deriveSelectionForTarget } = require(#{LOGIC_FILE.inspect});
      const dpeImpact  = #{DPE_IMPACT.to_json};
      const canonical  = #{CANONICAL_CODES.to_json};

      const snapshotBefore = JSON.stringify({ dpeImpact, canonical });

      const input = {
        currentDpeIdx: 5, targetIdx: 1,
        dpeImpact, canonicalCodes: canonical
      };
      const res1 = deriveSelectionForTarget(input);
      const res2 = deriveSelectionForTarget(input);

      const snapshotAfter = JSON.stringify({ dpeImpact, canonical });

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
           "res1=#{data["res1"].inspect}, res2=#{data["res2"].inspect}"
    assert data["inputsIntact"],
           "Non-mutation : dpeImpact et canonicalCodes ne doivent pas être modifiés. " \
           "Avant: #{data["before"]}, Après: #{data["after"]}"
  end
end
