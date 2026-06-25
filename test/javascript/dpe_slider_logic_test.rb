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
# Modèle (rappel) — pilotage BIDIRECTIONNEL jauge↔cases :
#   - JAUGE → CASES : ce que cette fonction calcule. Monter (cible plus
#     ambitieuse) ajoute des gestes. Descendre retire les gestes en trop par
#     impact croissant.
#   - INVARIANT : monter la cible ne RETIRE JAMAIS un geste coché.
#
# Cas testés :
#   I — Bug historique : currentlyChecked=5 dont menuiseries, C→B (montée) :
#       aucun retrait, menuiseries reste cochée.
#   J — Montée pure (départ minimal, cible ambitieuse) : checked grandit.
#   K — Descente : retraits autorisés, par impact croissant (moins utile
#       d'abord), sans descendre sous gainSouhaite.
#   L — Réactivité : un drag de cible qui CHANGE la situation doit modifier
#       checked. Pas de jauge inerte. C'est le bug du jour à fermer.
#   N — Pureté : entrées non mutées, idempotent.
#
# Si node n'est pas dans le PATH du runner de test, tous les tests sont skip
# avec un message clair (cf. setup).
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

  # ─── I. Bug historique menuiseries C→B : monotonie en montée ──────────
  # currentlyChecked = 5 gestes recommandés par Claude, incluant menuiseries.
  # apport = 4.5 ; cible C (gain 3) → cible B (gain 4). Monter ne doit
  # JAMAIS retirer un geste. En particulier, menuiseries reste cochée.

  test "I — montée C→B avec 5 gestes (dont menuiseries) : aucun retrait, menuiseries reste cochée" do
    initial = %w[isolation_toiture isolation_murs chauffage vmc menuiseries]
    # Apport initial = 1.0 + 1.0 + 1.5 + 0.5 + 0.5 = 4.5

    # Sur cible C (tgt=2, CUR=5, gain=3), apport (4.5) >= gain (3) → branche
    # "descente" théorique. Mais on retire seulement si ça ne fait pas passer
    # sous gain. Retirer menuiseries (0.5) ferait passer à 4.0 ≥ 3 ⇒ retiré.
    # Retirer vmc (0.5) → 3.5 ≥ 3 ⇒ retiré. Retirer iso_plancher (absent).
    # Retirer chauffe_eau (absent). Iso_toit (1.0) → 2.5 < 3 ⇒ pas retiré.
    # Donc à C, on s'allège à un minimum. C'est cohérent (la cible C est
    # MOINS ambitieuse que ce que couvrent 5 gestes Claude).
    res_c = run_derive(
      currentDpeIdx: 5, targetIdx: 2,
      currentlyChecked: initial,
      dpeImpact: DPE_IMPACT, canonicalCodes: CANONICAL_CODES
    )

    # Cœur du test : on MONTE de C à B. Quel que soit l'état à C, monter
    # vers B ne doit JAMAIS retirer un geste DÉJÀ coché à C.
    # On simule le drag C→B en prenant res_c["checked"] comme input.
    res_b = run_derive(
      currentDpeIdx: 5, targetIdx: 1,
      currentlyChecked: res_c["checked"],
      dpeImpact: DPE_IMPACT, canonicalCodes: CANONICAL_CODES
    )

    # MONOTONIE EN MONTÉE : checked à B ⊇ checked à C (aucun retrait).
    manquants = res_c["checked"] - res_b["checked"]
    assert_empty manquants,
                 "Montée C→B : aucun geste coché à C ne doit disparaître à B. Perdus: #{manquants.inspect}"

    # Et le cas direct du bug : si on part de la sélection Claude initiale
    # complète (5 gestes, qui couvre déjà B avec apport 4.5 >= 4), monter
    # directement à B ne doit toucher à RIEN — surtout pas menuiseries.
    res_b_direct = run_derive(
      currentDpeIdx: 5, targetIdx: 1,
      currentlyChecked: initial,
      dpeImpact: DPE_IMPACT, canonicalCodes: CANONICAL_CODES
    )
    assert_includes res_b_direct["checked"], "menuiseries",
                    "Cible B avec 5 gestes Claude (apport 4.5 ≥ gain 4) : menuiseries reste cochée. C'est exactement le bug d'origine."
    # apport actuel (4.5) > gain (4). Branche descente : tente de retirer
    # menuiseries (0.5) → 4.0 ≥ 4 ⇒ retiré. C'est OK ici, on n'est PAS
    # dans le scénario "montée depuis C" — on a directement chargé à B.
    # L'invariant qui mord vraiment, c'est la montée. Vérifions-le ailleurs.
  end

  # ─── J. Montée pure : départ minimal, cible ambitieuse ⇒ ajouts ─────

  test "J — montée pure (D → B depuis 1 geste) : checked grandit, aucun retrait" do
    initial = %w[chauffage] # apport 1.5
    cur     = 6              # CUR = G

    res_d = run_derive(
      currentDpeIdx: cur, targetIdx: 3, # D, gain 3
      currentlyChecked: initial,
      dpeImpact: DPE_IMPACT, canonicalCodes: CANONICAL_CODES
    )

    # apport(1.5) < gain(3) → ajouts par impact décroissant.
    # iso_toit 1.0 → cumul 2.5 ; iso_murs 1.0 → cumul 3.5 ≥ 3 STOP.
    # Donc res_d devrait être chauffage + iso_toit + iso_murs (3 gestes).
    assert_includes res_d["checked"], "chauffage", "chauffage initial conservé"
    assert_operator res_d["checked"].size, :>=, initial.size,
                    "Montée : checked ne rétrécit pas"
    refute (initial - res_d["checked"]).any?,
           "Initial intégralement préservé en montée"

    # Monter encore : D → B (gain 4)
    res_b = run_derive(
      currentDpeIdx: cur, targetIdx: 1, # B
      currentlyChecked: res_d["checked"],
      dpeImpact: DPE_IMPACT, canonicalCodes: CANONICAL_CODES
    )
    assert_empty (res_d["checked"] - res_b["checked"]),
                 "Montée D→B : aucun retrait"
    assert_operator res_b["checked"].size, :>=, res_d["checked"].size,
                    "Montée D→B : checked ≥ checked à D"
  end

  # ─── K. Descente : retraits OK, par impact croissant, sans sous-cible ─

  test "K — descente A→D depuis 5 gestes : peut retirer, par impact croissant, sans descendre sous gain" do
    initial = %w[isolation_toiture isolation_murs chauffage chauffe_eau menuiseries]
    # Apport = 1.0 + 1.0 + 1.5 + 0.5 + 0.5 = 4.5
    cur = 6 # G

    # Descente vers D : gain = 3. apport 4.5 > 3.
    # Retrait croissant : menuiseries (0.5) → 4.0 ≥ 3 ⇒ retiré.
    # chauffe_eau (0.5) → 3.5 ≥ 3 ⇒ retiré.
    # iso_toit (1.0) → 2.5 < 3 ⇒ NON retiré.
    # iso_murs (1.0) → 2.5 < 3 ⇒ NON retiré.
    # chauffage (1.5) → 3.0 ≥ 3 ⇒ retiré ? Oui ! cumul 3.0 == gain 3 → OK.
    #
    # Mais wait : l'ordre est croissant. Menuiseries (0.5), chauffe_eau (0.5),
    # vmc (0.5, absent), iso_plancher (0.5, absent), iso_toit (1.0),
    # iso_murs (1.0), chauffage (1.5). On itère dans cet ordre, on retire
    # tant que cumul - impact >= gain. Résultat : on garde au moins ce qui
    # est nécessaire pour rester à gain.
    res_d = run_derive(
      currentDpeIdx: cur, targetIdx: 3,
      currentlyChecked: initial,
      dpeImpact: DPE_IMPACT, canonicalCodes: CANONICAL_CODES
    )

    # Sanity : on est descendu — checked peut rétrécir.
    assert_operator res_d["checked"].size, :<, initial.size,
                    "Descente : au moins un retrait"

    # Apport résiduel >= gainSouhaite (on ne descend jamais sous la cible).
    apport_res = res_d["checked"].sum { |code| DPE_IMPACT[code] }
    assert_operator apport_res, :>=, 3.0,
                    "Apport résiduel #{apport_res} doit rester >= gain 3"

    # Les retraits doivent être des gestes à IMPACT FAIBLE (croissant).
    # Tous les gestes encore présents doivent avoir un impact >= au plus
    # gros retrait (sinon on aurait dû alléger le retrait plus lourd).
    # On vérifie spécifiquement : si menuiseries (0.5) est retirée, alors
    # chauffage (1.5) ne doit pas avoir été retiré "à sa place".
    retraits = initial - res_d["checked"]
    retraits.each do |r_code|
      r_impact = DPE_IMPACT[r_code]
      # Aucun geste plus lourd retiré que ce r_code, à moins qu'il ait fallu.
      # Simple version : impact des retraits ne doit pas être strictement
      # supérieur à l'impact du plus petit geste resté.
      restes_impacts = res_d["checked"].map { |c| DPE_IMPACT[c] }
      if restes_impacts.any?
        plus_petit_reste = restes_impacts.min
        assert_operator r_impact, :<=, plus_petit_reste + 0.001,
                        "Retrait '#{r_code}' (impact #{r_impact}) > plus petit reste (#{plus_petit_reste}) : violation du principe 'retirer le moins utile d'abord'"
      end
    end
  end

  # ─── L. Réactivité (LE BUG DU JOUR) ───────────────────────────────────
  # Un drag de jauge qui change la situation DOIT modifier checked.
  # Avant le fix d'aujourd'hui : la jauge devenait inerte parce que le socle
  # bloquait tout retrait. Maintenant : descente = retrait OK.

  test "L — réactivité : descendre la cible avec apport excédentaire DOIT alléger checked (jauge non inerte)" do
    initial = %w[isolation_toiture isolation_murs chauffage vmc menuiseries]
    # Apport = 4.5. CUR = F (5). Si l'utilisateur passe de C (gain 3) à
    # E (gain 1), apport (4.5) >> gain (1) : la jauge doit ALLÉGER.
    res_e = run_derive(
      currentDpeIdx: 5, targetIdx: 4, # E
      currentlyChecked: initial,
      dpeImpact: DPE_IMPACT, canonicalCodes: CANONICAL_CODES
    )

    refute_equal initial.sort, res_e["checked"].sort,
                 "Drag vers cible MOINS ambitieuse avec apport excédentaire DOIT changer checked. " \
                 "Avant fix d'aujourd'hui, la jauge restait inerte avec ce scénario. " \
                 "initial=#{initial.sort.inspect}, après=#{res_e["checked"].sort.inspect}"

    # Et la cible reste atteinte (apport >= gain).
    apport_res = res_e["checked"].sum { |code| DPE_IMPACT[code] }
    assert_operator apport_res, :>=, 1.0,
                    "Apport résiduel #{apport_res} doit rester >= gain 1"

    # Cas symétrique en montée : départ minimal, viser plus haut DOIT
    # ajouter des cases.
    res_b = run_derive(
      currentDpeIdx: 6, targetIdx: 1, # G → B, gain 5, depuis chauffage seul
      currentlyChecked: %w[chauffage],
      dpeImpact: DPE_IMPACT, canonicalCodes: CANONICAL_CODES
    )
    refute_equal %w[chauffage], res_b["checked"],
                 "Drag vers cible plus ambitieuse avec apport insuffisant DOIT ajouter des cases"
  end

  # ─── N. Pureté : idempotent + entrées non mutées ─────────────────────
  # Test scripté en UN SEUL process Node (deux Open3 successifs masqueraient
  # une mutation interne car Node redémarre à chaque appel).

  test "N — pureté : idempotent, n'altère pas les arrays/objets passés en entrée" do
    script = <<~JS
      const { deriveSelection } = require(#{LOGIC_FILE.inspect});
      const checked    = ['chauffage', 'isolation_toiture'];
      const dpeImpact  = #{DPE_IMPACT.to_json};
      const canonical  = #{CANONICAL_CODES.to_json};

      const snapshotBefore = JSON.stringify({ checked, dpeImpact, canonical });

      const input = {
        currentDpeIdx: 5, targetIdx: 1,
        currentlyChecked: checked,
        dpeImpact, canonicalCodes: canonical
      };
      const res1 = deriveSelection(input);
      const res2 = deriveSelection(input);

      const snapshotAfter = JSON.stringify({ checked, dpeImpact, canonical });

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
