// app/javascript/dpe_slider_logic.js
//
// Fonction PURE qui dérive la sélection de travaux correspondant à une cible
// DPE — modèle CASCADE MONOTONE, DÉTERMINISTE.
//
// ─── Modèle ──────────────────────────────────────────────────────────────
// Une cible (lettre DPE) = UNE sélection de travaux, fixe, calculée toujours
// pareil quel que soit le chemin des drags. La fonction NE PREND PAS l'état
// coché en entrée — la sortie ne dépend que de (currentDpeIdx, targetIdx,
// dpeImpact, canonicalCodes).
//
// Algorithme (cascade) :
//   1. Construire une "file de priorité" canonique : tous les gestes triés
//      par impact DPE décroissant, avec l'ordre canonicalCodes comme
//      tie-breaker stable (cas typique : 4 gestes à 0.5 conservent leur ordre
//      canonique). Cette file est la MÊME pour tous les appels.
//   2. Pour atteindre un gain G classes DPE : cocher les premiers gestes de
//      la file tant que le cumul d'impact reste strictement inférieur à G.
//   3. La sortie est donc un PRÉFIXE de la file canonique, déterminé
//      uniquement par G.
//
// ─── Garanties ───────────────────────────────────────────────────────────
//   1. CHEMIN-INDÉPENDANCE : deux appels avec le même targetIdx retournent
//      exactement la même sélection. Une lettre = une sélection. Plus jamais
//      de "B donne 3 sélections différentes selon le chemin" comme c'était
//      le cas avec deriveSelection(currentlyChecked).
//   2. CASCADE MONOTONE EMBOÎTÉE : pour deux cibles tgt1 < tgt2 (tgt1 plus
//      ambitieuse), gain1 > gain2, donc le préfixe de la file pour gain1 EST
//      un sur-ensemble du préfixe pour gain2. Monter ne retire jamais rien
//      — garanti par construction, pas par condition.
//   3. PURETÉ : aucune lecture DOM, aucun effet de bord, déterministe,
//      ne mute pas les arrays/objets passés en entrée.
//
// ─── Note produit : ordre de la file canonique ──────────────────────────
// Avec dpeImpact tel quel et canonicalCodes = TravauxMapperService::CANONICAL_CODES,
// l'ordre est : chauffage (1.5), isolation_toiture (1.0), isolation_murs
// (1.0), isolation_plancher_bas (0.5), chauffe_eau (0.5), vmc (0.5),
// menuiseries (0.5). Conséquence : menuiseries est en queue de file, donc
// cochée seulement pour les cibles très ambitieuses (gain ≥ 5 environ). Ce
// comportement est désormais cohérent (toujours pareil, jamais "parfois")
// et prévisible (cascade visible). Si la priorité produit voulait que
// menuiseries remonte (ex. argument "fenêtres = première chose qu'on voit"),
// il faut soit changer dpeImpact, soit changer l'ordre dans canonicalCodes.
// À discuter — pas une décision technique unilatérale.

function deriveSelectionForTarget({
  currentDpeIdx,
  targetIdx,
  dpeImpact,
  canonicalCodes
}) {
  // ─── Gain DPE souhaité (clampé à >= 0) ────────────────────────────────
  // targetIdx >= currentDpeIdx ⇒ aucune amélioration ⇒ sélection vide.
  const gainSouhaite = Math.max(0, currentDpeIdx - targetIdx);

  if (gainSouhaite === 0) {
    return { checked: [] };
  }

  // ─── File canonique : (code, impact) trié par impact décroissant ──────
  // Tie-break stable = ordre d'apparition dans canonicalCodes (Array.sort
  // est stable depuis ES2019 / Node 12+).
  //
  // Copie défensive : on map() depuis canonicalCodes en lecture seule, sans
  // muter l'array passé en entrée.
  const file = canonicalCodes
    .map(code => ({ code, impact: dpeImpact[code] || 0 }))
    .sort((a, b) => b.impact - a.impact);

  // ─── Cascade : préfixe de la file jusqu'à atteindre gainSouhaite ──────
  // Condition `cumul < gainSouhaite` (strict) : on coche tant qu'on n'a pas
  // encore atteint la cible. Une fois cumul ≥ gainSouhaite, on s'arrête.
  // Ce critère est aligné avec le code historique (cohérence cumul).
  const checked = [];
  let cumul = 0;
  for (const { code, impact } of file) {
    if (cumul >= gainSouhaite) break;
    checked.push(code);
    cumul += impact;
  }

  return { checked };
}

// ─── Double export : Node CommonJS pour les tests, global pour le browser ──
//
// En Node (test) :   const { deriveSelectionForTarget } = require('./dpe_slider_logic.js')
// En browser (show.html.erb) : le fichier est inclus inline dans un <script>
//   classique, donc `function deriveSelectionForTarget(...)` devient une
//   variable globale accessible par les autres scripts de la page. Le guard
//   ci-dessous évite `ReferenceError: module is not defined` côté browser.
if (typeof module !== 'undefined' && module.exports) {
  module.exports = { deriveSelectionForTarget };
}
