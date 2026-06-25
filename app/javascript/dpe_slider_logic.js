// app/javascript/dpe_slider_logic.js
//
// Fonction PURE qui dérive la nouvelle sélection de travaux quand l'utilisateur
// déplace la jauge DPE. Pilotage BIDIRECTIONNEL :
//
//   - JAUGE → CASES (cette fonction) : bouger la jauge ajuste les cases pour
//     atteindre la cible. Monter (cible plus ambitieuse) = AJOUTER. Descendre
//     = RETIRER ce qui devient inutile.
//
//   - CASES → JAUGE (côté show.html.erb, dans recalcTravaux) : cocher/décocher
//     recale la jauge sur la classe atteignable. Inchangé.
//
// INVARIANT CENTRAL — la garantie qui ferme le bug "menuiseries décochée en
// passant C→B" :
//
//   Monter la cible (targetIdx diminue ⇒ gainSouhaite augmente) ne retire
//   JAMAIS un geste déjà coché. L'ensemble checked ne rétrécit jamais en
//   passant à une cible plus ambitieuse.
//
// Descendre la cible PEUT retirer des gestes (c'est voulu : si la cible est
// moins ambitieuse, on allège). On retire dans l'ordre d'impact DPE CROISSANT
// (les moins utiles d'abord), pour ne jamais retirer un geste lourd quand on
// pouvait alléger sur un geste léger.
//
// Garanties :
//   1. MONOTONIE MONTÉE : currentlyChecked ⊆ checked dès que gainSouhaite ≥
//      apport actuel. Pas un seul geste perdu en visant mieux.
//   2. RÉACTIVITÉ : si la cible change et que l'apport des cases ne colle pas,
//      la fonction modifie checked. Pas de jauge inerte.
//   3. PURETÉ : aucune lecture DOM, aucun effet de bord, déterministe, ne mute
//      pas les arrays/objets passés en entrée.

function deriveSelection({
  currentDpeIdx,
  targetIdx,
  currentlyChecked,
  dpeImpact,
  canonicalCodes
}) {
  // ─── Copie défensive : on ne mute jamais les entrées ───────────────────
  const checkedSet = new Set(currentlyChecked);

  // ─── Gain DPE souhaité (clampé à >= 0) ─────────────────────────────────
  // targetIdx >= currentDpeIdx ⇒ aucune amélioration demandée ⇒ gain = 0
  // (autorise alors le retrait de tous les gestes inutiles).
  const gainSouhaite = Math.max(0, currentDpeIdx - targetIdx);

  // ─── Apport DPE actuellement couvert par les cases cochées ─────────────
  const apportActuel = sumImpact(checkedSet, dpeImpact);

  if (apportActuel < gainSouhaite) {
    // ─── MONTÉE : on AJOUTE des gestes hors checked pour combler le déficit.
    // Aucun retrait : la monotonie est préservée par construction (on ne
    // touche jamais aux cases déjà cochées dans cette branche).
    const candidats = candidatsHors(checkedSet, canonicalCodes, dpeImpact);
    // Tri stable décroissant par impact : gros gestes d'abord, ils couvrent
    // plus vite la cible. L'ordre canonicalCodes sert de tie-breaker stable
    // pour les gestes à impact égal (typique : les 4 gestes à 0.5).
    candidats.sort((a, b) => b.impact - a.impact);

    let cumul = apportActuel;
    for (const { code, impact } of candidats) {
      if (cumul >= gainSouhaite) break;
      checkedSet.add(code);
      cumul += impact;
    }
  } else if (apportActuel > gainSouhaite) {
    // ─── DESCENTE : on RETIRE des gestes en trop, par impact CROISSANT
    // (les moins utiles d'abord). On s'arrête dès qu'un retrait
    // supplémentaire ferait passer sous gainSouhaite — on veut COLLER au
    // plus près sans descendre dessous.
    //
    // Note : retirer "le moins utile d'abord" n'est pas un comportement
    // arbitraire — c'est le retrait le plus prévisible pour l'utilisateur
    // (les gestes lourds, qu'il "voit" comme structurants, restent).
    const candidats = candidatsDans(checkedSet, canonicalCodes, dpeImpact);
    // Tri stable croissant par impact.
    candidats.sort((a, b) => a.impact - b.impact);

    let cumul = apportActuel;
    for (const { code, impact } of candidats) {
      // Ne retire que si on reste >= gainSouhaite après retrait.
      if (cumul - impact < gainSouhaite) continue;
      checkedSet.delete(code);
      cumul -= impact;
    }
  }
  // Else (apportActuel === gainSouhaite) : on est pile à la cible, rien à
  // faire. checkedSet inchangé.

  return { checked: Array.from(checkedSet) };
}

// ─── Helpers internes (purs aussi) ──────────────────────────────────────

function sumImpact(set, dpeImpact) {
  let s = 0;
  for (const code of set) s += dpeImpact[code] || 0;
  return s;
}

// Codes canoniques HORS du set passé, avec leur impact. Préserve l'ordre
// canonicalCodes (utilisé comme tie-breaker stable par les sorts qui suivent).
function candidatsHors(set, canonicalCodes, dpeImpact) {
  const out = [];
  for (const code of canonicalCodes) {
    if (!set.has(code)) out.push({ code, impact: dpeImpact[code] || 0 });
  }
  return out;
}

// Codes canoniques DANS le set. Même remarque sur l'ordre.
function candidatsDans(set, canonicalCodes, dpeImpact) {
  const out = [];
  for (const code of canonicalCodes) {
    if (set.has(code)) out.push({ code, impact: dpeImpact[code] || 0 });
  }
  return out;
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
