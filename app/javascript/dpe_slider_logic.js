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
  travauxCosts,
  availableCodes
}) {
  const noop = { checked: [], derivedClasseIdx: currentDpeIdx, recale: false };

  // Aucune amélioration demandée : sélection vide, on affiche l'actuelle.
  if (targetIdx >= currentDpeIdx) return noop;
  if (!combinaisons) return noop;

  const ORDRE = "ABCDEFG";
  const costs = travauxCosts || {};
  // FILTRE PÉRIMÈTRE ACTIONNABLE (bug bien 215) : PropertyDpeMatrixService
  // calcule TOUJOURS 2^7 combinaisons, mais la vue ne rend une checkbox
  // que pour les gestes proposés par Claude (travaux_groupes). Si l'algo
  // renvoyait `menuiseries` alors qu'aucune case ne l'incarne, le set
  // final coché est amputé silencieusement et la classe re-dérivée
  // s'écarte de la classe annoncée. On écarte donc ici toute combinaison
  // qui requiert un code hors availableCodes.
  //   - availableCodes = Array de codes présents dans le DOM (data-code
  //     sur .travail-check),
  //   - null/undefined = pas de filtre (rétro-compat pour tests unitaires
  //     et cas où l'appelant ne connaît pas le périmètre).
  const available = availableCodes ? new Set(availableCodes) : null;

  // Énumération : chaque entrée valide → {codes, classeIdx, cost}.
  const options = [];
  for (const key in combinaisons) {
    if (!Object.prototype.hasOwnProperty.call(combinaisons, key)) continue;
    const entry = combinaisons[key];
    if (!entry || typeof entry.classe !== 'string') continue;
    const classeIdx = ORDRE.indexOf(entry.classe);
    if (classeIdx < 0) continue;
    const codes = key === "" ? [] : key.split(",");
    // Filtre périmètre : combinaison écartée dès qu'un code n'est pas
    // dans le DOM. Une sélection partielle donnerait une classe finale
    // différente à la re-dérivation → mensonge.
    if (available && codes.some(function(c){ return !available.has(c); })) continue;
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
// Fonction PURE — AFFORDANCE : classes qui NE SONT PAS un point d'arrivée.
//
// Deux sémantiques COALESCÉES sous le même retour, parce que la vue
// applique le même traitement visuel (hachures + line-through + tooltip) :
//
//   • DOMINÉE : deriveSelectionForTarget(X) retourne une classe
//     STRICTEMENT MEILLEURE que X (idx < X). Cliquer sur X recale vers
//     mieux, moins cher. Cas historique « E dominé par D » observé en
//     prod sur un bien F.
//
//   • INATTEIGNABLE : deriveSelectionForTarget(X) retourne une classe
//     STRICTEMENT PIRE que X (idx > X). Cliquer sur X ne peut pas
//     atteindre X — la matrice tombe sur le fallback pessimiste. Cas
//     bien 232 (copro classe E, 3 gestes) : cliquer A, B ou C recale
//     vers D, la meilleure classe atteignable avec les gestes proposés.
//
// Dans les deux cas, X n'est pas un point d'arrivée du slider. La vue
// doit donc marquer X pareil (mais avec un tooltip différent — cf.
// initShow qui appelle deriveSelectionForTarget pour connaître la
// direction du recalage).
//
// Balayage : toutes les classes STRICTEMENT MEILLEURES que currentDpeIdx
// (targetIdx < currentDpeIdx). currentDpeIdx elle-même n'est pas un
// point d'arrivée (le slider est clampé à cur-1) donc hors périmètre.
//
function computeDominatedClasses({
  currentDpeIdx,
  combinaisons,
  travauxCosts,
  availableCodes
}) {
  const dominated = [];
  for (let i = 0; i < currentDpeIdx; i++) {
    // MÊME périmètre availableCodes que deriveSelectionForTarget — sinon
    // l'affordance mentirait (« E dominé par D » alors que la sélection
    // D pour ce bien exigerait un geste sans checkbox).
    const res = deriveSelectionForTarget({
      currentDpeIdx,
      targetIdx: i,
      combinaisons,
      travauxCosts,
      availableCodes
    });
    if (res.derivedClasseIdx !== i) dominated.push(i);
  }
  return dominated;
}

// ─────────────────────────────────────────────────────────────────────────
// Fonction PURE — meilleure classe atteignable + drapeau d'inaccessibilité.
//
// Balaye TOUTES les classes strictement meilleures que la classe actuelle
// (i ∈ [0, currentDpeIdx[), applique deriveSelectionForTarget à chacune et
// classe chaque i en trois cas :
//
//   • ATTEIGNABLE   : derivedClasseIdx === i.
//     Le drag sur i s'arrête sur i — la classe est un vrai point d'arrivée.
//   • DOMINÉE       : derivedClasseIdx <  i.
//     Le drag sur i recale vers MIEUX (moins cher, meilleure classe).
//     Une classe seulement dominée NE PLAFONNE RIEN — une meilleure
//     classe est atteignable en cliquant plus haut.
//   • INATTEIGNABLE : derivedClasseIdx >  i.
//     La matrice tombe sur le fallback pessimiste. Aucun geste combiné
//     dans le périmètre ne descend jusqu'à i.
//
// Retour :
//   {
//     bestAchievableIdx: min(derivedClasseIdx) sur i ∈ [0, currentDpeIdx[
//                       — inclut les i atteignables (dérivent i eux-mêmes)
//                       ET les valeurs dérivées des dominées / inatteignables
//                       (car dériver = la meilleure classe réellement obtenue
//                        pour cette cible). Au pire currentDpeIdx (pas de
//                        classe meilleure atteinte).
//     hasUnreachable   : true dès qu'il existe un i tel que derivedClasseIdx > i.
//                       C'est le PRÉDICAT QUI PILOTE l'affichage de la note
//                       de plafonnement dans la vue — un cas purement dominé
//                       (E → D sur une maison F) ne doit RIEN afficher.
//   }
//
// ── Pourquoi séparer bestAchievableIdx et hasUnreachable ──
// L'ancien code de la vue calculait bestAchievableIdx en itérant sur les
// classes MARQUÉES par computeDominatedClasses (sémantique coalescée
// dominée/inatteignable). Sur une maison F où seule E était dominée par D,
// le min tombait sur D et la note affichait « plafond D » alors que
// A est atteignable directement en cliquant A. La note confondait les
// deux sémantiques que le commit 42f7bc8 avait pourtant introduites côté
// tooltip. On sépare ici proprement : la meilleure classe atteignable est
// TOUJOURS calculée sur le balayage complet, et l'AFFICHAGE de la note
// est conditionné à hasUnreachable (pas de note quand rien n'est plafonné).
function computeBestAchievable({
  currentDpeIdx,
  combinaisons,
  travauxCosts,
  availableCodes
}) {
  var bestAchievableIdx = currentDpeIdx;
  var hasUnreachable = false;
  for (var i = 0; i < currentDpeIdx; i++) {
    var res = deriveSelectionForTarget({
      currentDpeIdx: currentDpeIdx,
      targetIdx: i,
      combinaisons: combinaisons,
      travauxCosts: travauxCosts,
      availableCodes: availableCodes
    });
    if (res.derivedClasseIdx < bestAchievableIdx) {
      bestAchievableIdx = res.derivedClasseIdx;
    }
    if (res.derivedClasseIdx > i) {
      hasUnreachable = true;
    }
  }
  return { bestAchievableIdx: bestAchievableIdx, hasUnreachable: hasUnreachable };
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
    computeBestAchievable,
    targetIdxFromSegment
  };
}
