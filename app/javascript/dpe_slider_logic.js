// app/javascript/dpe_slider_logic.js
//
// Fonction PURE qui dérive la sélection de travaux correspondant à une cible
// DPE — modèle CASCADE MONOTONE PAR PRÉFIXES.
//
// ─── Modèle (Temps 3b-2 commit 3, final) ─────────────────────────────────
// Entrées : (currentDpeIdx, targetIdx, prioriteGestes, combinaisons) où
//   - prioriteGestes : liste ordonnée de codes (gain EP décroissant
//     SPÉCIFIQUE au bien, calculée serveur par PropertyDpeMatrixService).
//   - combinaisons   : lookup { "<clé triée alphabétique>": {classe, ...} }.
//
// Cascade : itérer k de 0 à N, prendre le préfixe prioriteGestes.slice(0, k),
// construire la clé prefixe.slice().sort().join(",") — format exact de
// PropertyDpeMatrixService#calculer_combinaisons (l. 116) — et chercher le
// plus petit k tel que combinaisons[clé].classe ≤ targetClasse.
//
// ─── Garanties (P/Q/I/N) ─────────────────────────────────────────────────
//   1. CHEMIN-INDÉPENDANCE : deux appels avec mêmes args ⇒ même sélection.
//      Aucune lecture DOM, aucun état global, aucune horloge.
//   2. CASCADE MONOTONE EMBOÎTÉE : pour deux cibles tgt1 < tgt2 (tgt1 plus
//      ambitieuse), sélection(tgt1) ⊇ sélection(tgt2). Garantie par
//      construction (préfixes emboîtés) + monotonie de la matrice (testée
//      au Temps 3b-1 : ajouter un geste ne dégrade jamais la classe).
//   3. PURETÉ : entrées non mutées (slice() défensif), idempotent.
//   4. INCLUSION STABLE de menuiseries : pour cibles ambitieuses qui exigent
//      le préfixe long, menuiseries est cochée — stable, pas "parfois".
//
// ─── Note produit ────────────────────────────────────────────────────────
// L'ordre dans prioriteGestes est SPÉCIFIQUE AU BIEN. Sur ID 69 (1995
// :partiel) le top 1 est isolation_murs (gain EP +95,9). Sur Tilleuls
// (1962 :non_isole) le top 1 est chauffage (gain EP +128,0). La cascade
// reflète le LEVIER RÉEL du bien, plus un classement forfaitaire.

function deriveSelectionForTarget({
  currentDpeIdx,
  targetIdx,
  prioriteGestes,
  combinaisons
}) {
  // targetIdx >= currentDpeIdx ⇒ aucune amélioration ⇒ sélection vide.
  if (targetIdx >= currentDpeIdx) {
    return { checked: [] };
  }

  // Ordre canonique DPE figé par l'arrêté : "ABCDEFG" (A meilleur = idx 0).
  const ORDRE = "ABCDEFG";

  for (let k = 0; k <= prioriteGestes.length; k++) {
    // slice() — copie défensive (pureté : ne mute pas prioriteGestes).
    const prefixe = prioriteGestes.slice(0, k);
    // Tri lexicographique côté JS — coïncide avec Ruby Array#sort sur ASCII.
    const cle = prefixe.slice().sort().join(",");
    const entry = combinaisons[cle];
    if (!entry || typeof entry.classe !== 'string') continue;
    const classeIdx = ORDRE.indexOf(entry.classe);
    if (classeIdx >= 0 && classeIdx <= targetIdx) {
      return { checked: prefixe };
    }
  }
  // Aucun préfixe n'atteint la cible — on rend tout (préfixe complet).
  // Cas typique : cible A demandée mais matrice s'arrête à B. Honnête.
  return { checked: prioriteGestes.slice() };
}

// ─── Double export : Node CommonJS pour les tests, global pour le browser ──
if (typeof module !== 'undefined' && module.exports) {
  module.exports = { deriveSelectionForTarget };
}
