// app/javascript/dpe_slider_logic.js
//
// Trois fonctions PURES qui pilotent la jauge DPE interactive :
//   - deriveSelectionForTarget  : cible DPE → sélection travaux + classe
//     réellement atteinte + flag "recalé" (sens JAUGE → CASES).
//   - deriveTargetFromSelection : cases cochées → classe atteignable
//     (sens CASES → JAUGE, source de vérité unique de l'objectif affiché).
//   - computeDominatedClasses   : classes qui ne seront jamais un point
//     d'arrivée du slider (affordance visuelle).
//
// ─── Modèle "AU MOINS X, LE MOINS CHER" (post-observation prod) ──────────
//
// Historique : la version précédente cherchait le MATCH EXACT sur la
// classe visée. Symptôme observé en prod sur un bien F :
//   OBJECTIF D → chauffage seul (~13 000 €)
//   OBJECTIF E → toiture+murs+planchers (~26 500 €)
// Viser une classe PIRE coûtait 2× plus cher. La cause : un "détour" de
// travaux plus coûteux pour atterrir EXACTEMENT sur E, alors qu'une
// combinaison bon marché sautait à D. Absurde côté produit.
//
// NOUVELLE SÉMANTIQUE :
//   - deriveSelectionForTarget(X) filtre les combinaisons dont classeIdx
//     ≤ X ("X ou mieux"), retourne LA MOINS CHÈRE. Le coût est monotone
//     croissant en la difficulté par construction (moins d'options
//     qualifiées en montant).
//   - Le pin/label se posent sur la classe RÉELLEMENT dérivée de la
//     sélection retournée. Si le user visait E mais la moins chère saute
//     à D, on affiche D — pas de mensonge, on ne prétend pas viser E
//     alors qu'on donne D.
//   - Flag `recale: true` renvoyé quand la classe dérivée diffère de la
//     classe visée. Utilisé par la vue pour afficher un microtexte du
//     genre "Bonne nouvelle : atteindre D coûte moins cher que E —
//     objectif recalé sur D". Principe projet : jamais de recalage
//     silencieux.
//
// Fallback pessimiste conservé (mais DÉGRADÉ) : si vraiment RIEN
// n'atteint la cible ou mieux (matrice qui manque toutes les entrées
// ≤ target), on retombe sur la classe la plus proche du côté pire,
// plafonnée à currentDpeIdx. Ce chemin est désormais rare — il ne
// s'active que sur des matrices tronquées, pas dans le cours normal.
//
// ─── Garanties conservées ───────────────────────────────────────────────
//   * PLAFOND ANTI-DÉGRADATION : jamais une sélection dont la classe
//     dérivée serait pire que la classe actuelle.
//   * DÉTERMINISME : deux appels avec mêmes args ⇒ même sortie exacte.
//   * PURETÉ : entrées non mutées.
//   * MONOTONIE DES COÛTS : cost(sélection(F)) ≤ cost(sélection(E)) ≤ …
//     ≤ cost(sélection(A)) — par construction (filtre inclusif).
//
// Retour de deriveSelectionForTarget :
//   {
//     checked:           Array<string>,  // codes de travaux à cocher
//     derivedClasseIdx:  Number (0..6),  // classe réellement atteinte
//     recale:            Boolean         // true si derivedClasseIdx < targetIdx
//                                         // (== "on va faire mieux que demandé")
//   }

function deriveSelectionForTarget({
  currentDpeIdx,
  targetIdx,
  combinaisons,
  travauxCosts
}) {
  const noop = { checked: [], derivedClasseIdx: currentDpeIdx, recale: false };

  // Aucune amélioration demandée : sélection vide, on affiche l'actuelle.
  if (targetIdx >= currentDpeIdx) return noop;
  if (!combinaisons) return noop;

  const ORDRE = "ABCDEFG";
  const costs = travauxCosts || {};

  // Énumération : chaque entrée valide → {codes, classeIdx, cost}.
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

  // Ordre total déterministe : cost, puis cardinalité, puis lexico.
  const cheaperFirst = (a, b) => {
    if (a.cost !== b.cost) return a.cost - b.cost;
    if (a.codes.length !== b.codes.length) return a.codes.length - b.codes.length;
    return a.codes.slice().sort().join(',') < b.codes.slice().sort().join(',') ? -1 : 1;
  };

  // 1. Sémantique "au moins X" : filtre classeIdx <= targetIdx (target ou mieux).
  //    Sous-contrainte anti-dégradation : classe ≤ currentDpeIdx (implicite ici
  //    puisque targetIdx < currentDpeIdx et on ne descend que).
  const atLeast = options.filter(o => o.classeIdx <= targetIdx);
  if (atLeast.length > 0) {
    atLeast.sort(cheaperFirst);
    const best = atLeast[0];
    return {
      checked:          best.codes.slice(),
      derivedClasseIdx: best.classeIdx,
      recale:           best.classeIdx < targetIdx
    };
  }

  // 2. Aucun ensemble n'atteint la cible ou mieux (matrice tronquée / bien
  //    peu améliorable). Fallback pessimiste — la classe la plus proche
  //    côté pire, plafonnée à currentDpeIdx pour respecter le plafond
  //    anti-dégradation. Chemin de secours honnête ("on a fait de notre
  //    mieux mais on n'atteint pas la cible").
  const pessimists = options.filter(
    o => o.classeIdx > targetIdx && o.classeIdx <= currentDpeIdx
  );
  if (pessimists.length > 0) {
    pessimists.sort((a, b) => {
      if (a.classeIdx !== b.classeIdx) return a.classeIdx - b.classeIdx;
      return cheaperFirst(a, b);
    });
    const best = pessimists[0];
    return {
      checked:          best.codes.slice(),
      derivedClasseIdx: best.classeIdx,
      recale:           true  // on n'atteint pas ce qui est demandé
    };
  }

  // 3. Rien de valide (matrice complètement vide/corrompue) : noop.
  return noop;
}

// ─────────────────────────────────────────────────────────────────────────
// Fonction PURE — sens INVERSE : sélection de travaux → classe atteignable.
//
// Contrat :
//   - source de vérité unique = codesActifs (ensemble des cases cochées),
//   - retourne l'idx (0..6 pour A..G) de la classe atteignable par cet
//     ensemble, tel que pré-calculé par PropertyDpeMatrixService,
//   - PLAFOND ANTI-DÉGRADATION : on ne retourne JAMAIS un idx pire que
//     currentDpeIdx. La matrice est parfois calculée sur un état initial
//     reconstruit qui n'aboutit pas exactement à la classe DPE observée
//     (Property#dpe_class venant de Claude). Si le moteur pense que ""
//     donne G alors que le bien est F, on affiche F — "pas d'amélioration"
//     est honnête ; "G" (dégradation) est absurde.
//   - FALLBACK PESSIMISTE : si la matrice est absente, l'entrée manquante
//     ou classe non-string, retourne currentDpeIdx (même sémantique).
//
function deriveTargetFromSelection({
  codesActifs,
  combinaisons,
  currentDpeIdx
}) {
  if (!combinaisons) return currentDpeIdx;

  const ORDRE = "ABCDEFG";
  const cle = codesActifs.slice().sort().join(',');
  const entry = combinaisons[cle];

  if (!entry || typeof entry.classe !== 'string') return currentDpeIdx;

  const idx = ORDRE.indexOf(entry.classe);
  if (idx < 0) return currentDpeIdx;

  return Math.min(idx, currentDpeIdx);
}

// ─────────────────────────────────────────────────────────────────────────
// Fonction PURE — AFFORDANCE : classes DOMINÉES (jamais un point d'arrivée).
//
// Une classe X est DOMINÉE si deriveSelectionForTarget(X) retourne une
// sélection dont la classe dérivée est STRICTEMENT MEILLEURE que X.
// Autrement dit : cliquer sur X recalera toujours vers une classe
// meilleure et moins chère. C'est le cas de figure « E dominé par D »
// observé en prod.
//
// Utilisation prévue par la vue : au chargement, réduire l'opacité des
// segments dominés + poser un `title` explicatif ("cette classe recalera
// automatiquement"). L'utilisateur comprend AVANT de cliquer, plutôt
// qu'après avoir vu le pin sauter.
//
// Balayage : toutes les classes STRICTEMENT MEILLEURES que currentDpeIdx
// (targetIdx < currentDpeIdx). currentDpeIdx elle-même n'est pas un
// point d'arrivée (le slider est clampé à cur-1) donc hors périmètre.
//
function computeDominatedClasses({
  currentDpeIdx,
  combinaisons,
  travauxCosts
}) {
  const dominated = [];
  for (let i = 0; i < currentDpeIdx; i++) {
    const res = deriveSelectionForTarget({
      currentDpeIdx,
      targetIdx: i,
      combinaisons,
      travauxCosts
    });
    if (res.derivedClasseIdx < i) dominated.push(i);
  }
  return dominated;
}

// ─────────────────────────────────────────────────────────────────────────
// Fonction PURE — lit l'index du segment cliqué depuis son data-idx.
//
// Utilisée par le event delegation sur .dpe-track côté vue. Extraite ici
// pour être testable en Node avec un mock (pas de dépendance DOM native).
//
// Contrat :
//   - Entrée : élément (ou mock) avec .dataset.idx string "0".."6".
//   - Sortie : entier 0..6 si valide, sinon null.
//   - Aucune valeur > 6 ou < 0 acceptée (protège d'un data-idx malformé).
//
// Motivation : le bug prod bien 214/215 « clic sur B ou E ignoré » venait
// de la mapping GÉOMÉTRIQUE thumbWidth→value du range input. En passant
// par un handler qui lit data-idx explicite, on court-circuite toute
// géométrie. La fonction pure garantit que la lecture est déterministe.
//
function targetIdxFromSegment(seg) {
  if (!seg || !seg.dataset || seg.dataset.idx === undefined) return null;
  var idx = parseInt(seg.dataset.idx, 10);
  if (isNaN(idx) || idx < 0 || idx > 6) return null;
  return idx;
}

// ─── Double export : Node CommonJS pour les tests, global pour le browser ──
if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    deriveSelectionForTarget,
    deriveTargetFromSelection,
    computeDominatedClasses,
    targetIdxFromSegment
  };
}
