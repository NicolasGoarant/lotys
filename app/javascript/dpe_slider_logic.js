// app/javascript/dpe_slider_logic.js
//
// Deux fonctions PURES qui pilotent la jauge DPE interactive :
//   - deriveSelectionForTarget : cible DPE → sélection de travaux à cocher
//     (sens JAUGE → CASES).
//   - deriveTargetFromSelection : cases cochées → classe atteignable
//     (sens CASES → JAUGE, source de vérité unique de l'objectif affiché).
//
// ─── Modèle (post-fix anomalies 1 et 2) ───────────────────────────────────
// Entrée matrice : combinaisons = lookup { "<clé triée alphabétique>":
//   {classe, ...} }, format exact de PropertyDpeMatrixService#calculer_combinaisons.
// La matrice contient 2^N entrées (128 pour N=7 gestes) → énumérable
// intégralement côté client à moindre coût.
//
// ─── deriveSelectionForTarget — algorithme ────────────────────────────────
// L'ancien modèle "cascade par préfixes de prioriteGestes" a été remplacé
// par une ÉNUMÉRATION complète de la matrice. Motivation : certaines
// classes (E notamment) sont ATTEIGNABLES par une combinaison non-préfixe
// (ex : isolation_toiture SEULE), donc le drag jauge sur E court-circuitait
// vers D ou F et le pin rebondissait. En énumérant, on trouve TOUJOURS
// l'ensemble le moins cher qui atteint la classe visée (si elle existe).
//
//   1. Recherche EXACTE : parmi toutes les combinaisons dont classe ==
//      targetIdx, retourne la moins chère (Σ travauxCosts). Ties brisés
//      par cardinalité croissante puis lexicographique (déterminisme).
//   2. FALLBACK PESSIMISTE : si aucune combinaison n'atteint EXACTEMENT
//      targetIdx, on retourne la combinaison dont la classe est la plus
//      PROCHE de targetIdx CÔTÉ PIRE (classeIdx > targetIdx). Jamais mieux
//      que ce que l'utilisateur a demandé — cohérent avec le principe
//      projet "pas d'affichage plus favorable que ce que les données
//      justifient". Contrainte de plafond : classeIdx <= currentDpeIdx —
//      on ne propose jamais une sélection qui empirerait par rapport à
//      la classe actuelle du bien.
//   3. Sinon (rien) : sélection vide.
//
// ─── Garanties ────────────────────────────────────────────────────────────
//   * Chemin-indépendance : deux appels avec mêmes args ⇒ même sélection.
//   * Pureté : entrées non mutées.
//   * Stabilité slider (anomalie 2) : glisser vers X et re-glisser vers
//     X redonne EXACTEMENT le même ensemble, donc la même classe dérivée.
//     Plus de rebond du pin entre deux valeurs différentes pour la même
//     cible slider.

function deriveSelectionForTarget({
  currentDpeIdx,
  targetIdx,
  combinaisons,
  travauxCosts
}) {
  // targetIdx >= currentDpeIdx ⇒ aucune amélioration ⇒ sélection vide.
  if (targetIdx >= currentDpeIdx) {
    return { checked: [] };
  }
  if (!combinaisons) {
    return { checked: [] };
  }

  const ORDRE = "ABCDEFG";
  const costs = travauxCosts || {};

  // Énumération : matérialiser chaque entrée valide en { codes, classeIdx, cost }.
  const options = [];
  for (const key in combinaisons) {
    if (!Object.prototype.hasOwnProperty.call(combinaisons, key)) continue;
    const entry = combinaisons[key];
    if (!entry || typeof entry.classe !== 'string') continue;
    const classeIdx = ORDRE.indexOf(entry.classe);
    if (classeIdx < 0) continue;
    const codes = key === "" ? [] : key.split(",");
    let cost = 0;
    for (let i = 0; i < codes.length; i++) {
      cost += costs[codes[i]] || 0;
    }
    options.push({ codes, classeIdx, cost });
  }

  // Comparateur "moins cher" — tie-breaks pour un ordre total déterministe :
  // cost < cardinalité < lexicographique (par la clé triée).
  const cheaperFirst = (a, b) => {
    if (a.cost !== b.cost) return a.cost - b.cost;
    if (a.codes.length !== b.codes.length) return a.codes.length - b.codes.length;
    return a.codes.slice().sort().join(',') < b.codes.slice().sort().join(',') ? -1 : 1;
  };

  // 1. Match exact sur targetIdx : la moins chère gagne.
  const exacts = options.filter(o => o.classeIdx === targetIdx);
  if (exacts.length > 0) {
    exacts.sort(cheaperFirst);
    return { checked: exacts[0].codes.slice() };
  }

  // 2. Pessimist : classe > targetIdx (pire que demandé) ET <= currentDpeIdx
  //    (pas pire que la classe actuelle). Plus proche de targetIdx d'abord
  //    (classeIdx croissant), puis moins cher.
  const pessimists = options.filter(
    o => o.classeIdx > targetIdx && o.classeIdx <= currentDpeIdx
  );
  if (pessimists.length > 0) {
    pessimists.sort((a, b) => {
      if (a.classeIdx !== b.classeIdx) return a.classeIdx - b.classeIdx;
      return cheaperFirst(a, b);
    });
    return { checked: pessimists[0].codes.slice() };
  }

  // 3. Rien de valide (matrice vide ou entrées corrompues) : sélection vide.
  return { checked: [] };
}

// ─────────────────────────────────────────────────────────────────────────
// Fonction PURE — sens INVERSE : sélection de travaux → classe atteignable.
//
// Contrat :
//   - source de vérité unique = codesActifs (ensemble des cases cochées),
//   - retourne l'idx (0..6 pour A..G) de la classe atteignable par cet
//     ensemble, tel que pré-calculé par PropertyDpeMatrixService,
//   - PLAFOND ANTI-DÉGRADATION (fix anomalie 1) : on ne retourne JAMAIS
//     un idx pire que currentDpeIdx. Motivation : la matrice est parfois
//     calculée sur un état initial reconstruit qui n'aboutit pas
//     exactement à la classe DPE observée (Property#dpe_class venant de
//     Claude). Si le moteur pense que "" ou un geste minimal donne G
//     alors que le bien est F, on affiche F — "pas d'amélioration" est
//     honnête ; "G" (dégradation) est absurde et déroutant.
//   - FALLBACK PESSIMISTE : si la matrice est absente, l'entrée manquante
//     ou classe non-string, retourne currentDpeIdx (même sémantique que
//     le plafond).
//
// Garanties :
//   * Chemin-indépendance : la sortie ne dépend QUE de codesActifs et de la
//     matrice figée. Deux ensembles identiques → même objectif, quel que
//     soit l'historique.
//   * Purity : entrées non mutées.
//
function deriveTargetFromSelection({
  codesActifs,
  combinaisons,
  currentDpeIdx
}) {
  // Fallback pessimiste : pas de matrice → afficher classe actuelle.
  if (!combinaisons) return currentDpeIdx;

  const ORDRE = "ABCDEFG";
  const cle = codesActifs.slice().sort().join(',');
  const entry = combinaisons[cle];

  if (!entry || typeof entry.classe !== 'string') {
    return currentDpeIdx;
  }

  const idx = ORDRE.indexOf(entry.classe);
  if (idx < 0) return currentDpeIdx;

  // Plafond anti-dégradation : jamais pire que la classe actuelle.
  // Math.min sur des idx où 0=A (meilleur) et 6=G (pire) →
  // min(matrixIdx, currentDpeIdx) = le meilleur des deux = le plus petit idx.
  return Math.min(idx, currentDpeIdx);
}

// ─── Double export : Node CommonJS pour les tests, global pour le browser ──
if (typeof module !== 'undefined' && module.exports) {
  module.exports = { deriveSelectionForTarget, deriveTargetFromSelection };
}
