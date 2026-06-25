// app/javascript/dpe_slider_logic.js
//
// Fonction PURE qui dérive la sélection de travaux quand la jauge DPE bouge.
//
// Modèle :
//   - SOCLE = travaux qu'on ne touche JAMAIS automatiquement.
//             Au runtime, c'est l'union de :
//               * INITIAL_SOCLE = travaux cochés au chargement (reco Claude
//                 + ce que l'utilisateur avait persisté en DB).
//               * USER_SOCLE    = travaux que l'utilisateur a cochés à la main
//                 depuis le chargement (et pas redécochés).
//   - ADDED_BY_SLIDER = ce que la jauge a ajouté par-dessus le socle pour
//             atteindre une cible plus ambitieuse. C'est le SEUL ensemble que
//             les mouvements de jauge ont le droit de retirer.
//
// Garanties de cette fonction :
//   1. INVIOLABILITÉ du socle : `checked` inclut TOUJOURS tout le socle, quel
//      que soit `targetIdx`. Aucun geste du socle n'est jamais retiré par la
//      jauge.
//   2. MONOTONIE en cible : pour un socle fixé, augmenter la cible (i.e. baisser
//      `targetIdx`) ne fait jamais rétrécir `checked` (cf. preuve dans le test J).
//   3. PURETÉ : aucune lecture DOM, aucun effet de bord, déterministe, ne mute
//      pas les arrays/Set passés en entrée.
//
// Choix de design : `addedBySlider` est accepté en entrée pour symétrie de
// signature, MAIS n'est PAS consulté dans le calcul. Le résultat dépend
// uniquement de (currentDpeIdx, targetIdx, socle, dpeImpact, canonicalCodes).
// Ce choix rend la fonction idempotente et indépendante de l'historique des
// drags : aller de C directement à A donne le même résultat que C→B→A. On
// préfère la prévisibilité à la fidélité à un historique LIFO qui serait
// invisible pour l'utilisateur.

function deriveSelection({
  currentDpeIdx,
  targetIdx,
  socle,
  addedBySlider, // accepté pour symétrie, non consulté (cf. note ci-dessus)
  dpeImpact,
  canonicalCodes
}) {
  // ─── Copies défensives : on ne mute jamais les entrées ─────────────────
  const socleSet = new Set(socle);

  // ─── Gain DPE souhaité (clampé à >= 0) ─────────────────────────────────
  // targetIdx >= currentDpeIdx ⇒ aucune amélioration demandée ⇒ gain = 0
  // (la jauge ne demande aucun ajout, le socle reste, rien d'autre n'est coché).
  const gainSouhaite = Math.max(0, currentDpeIdx - targetIdx);

  // ─── Apport DPE déjà couvert par le socle ──────────────────────────────
  // Le socle est intouchable et coché. Son apport DPE compte dans le total.
  // Si le socle couvre déjà gainSouhaite, la jauge n'a rien à ajouter.
  let apportSocle = 0;
  for (const code of socleSet) {
    apportSocle += dpeImpact[code] || 0;
  }

  // ─── Construction du résultat ──────────────────────────────────────────
  // checked démarre = socle (inviolable). addedBySlider démarre vide.
  const checkedSet = new Set(socleSet);
  const newAddedSet = new Set();

  if (gainSouhaite > apportSocle) {
    // Le socle ne suffit pas : on AJOUTE des gestes HORS socle pour combler.
    const reste = gainSouhaite - apportSocle;

    // Candidats : codes canoniques hors socle (avec leur impact).
    // L'ordre des codes canoniques (`canonicalCodes`) sert de tie-breaker
    // stable quand plusieurs gestes ont le même impact (typique : isolation
    // plancher / chauffe-eau / VMC / menuiseries sont tous à 0.5).
    const candidates = canonicalCodes
      .filter(code => !socleSet.has(code))
      .map(code => ({ code, impact: dpeImpact[code] || 0 }));

    // Tri stable décroissant par impact. JS Array#sort est stable depuis
    // ES2019 (Node 12+). Donc en cas d'égalité d'impact, l'ordre d'apparition
    // dans `canonicalCodes` est préservé.
    candidates.sort((a, b) => b.impact - a.impact);

    // Glouton : coche tant que le cumul d'apports ajoutés est strictement
    // inférieur au reste à combler. La condition `cumul < reste` (et non `<=`)
    // garantit qu'on s'arrête dès qu'on a atteint la cible, sans sur-cocher.
    let cumul = 0;
    for (const { code, impact } of candidates) {
      if (cumul < reste) {
        checkedSet.add(code);
        newAddedSet.add(code);
        cumul += impact;
      }
    }
  }
  // Else : gainSouhaite <= apportSocle. Le socle couvre tout seul. La jauge
  // n'ajoute RIEN. Si addedBySlider précédent contenait des gestes, ils sont
  // implicitement retirés (newAddedSet vide). Aucun geste du socle ne sort.

  return {
    checked:       Array.from(checkedSet),
    addedBySlider: Array.from(newAddedSet)
  };
}

// ─── Double export : Node CommonJS pour les tests, global pour le browser ──
//
// En Node (test) :   const { deriveSelection } = require('./dpe_slider_logic.js')
// En browser (show.html.erb) : le fichier est inclus inline dans un <script>
//   classique, donc `function deriveSelection(...)` devient une variable
//   globale accessible par les autres scripts de la page. Le guard ci-dessous
//   évite `ReferenceError: module is not defined` côté browser.
if (typeof module !== 'undefined' && module.exports) {
  module.exports = { deriveSelection };
}
