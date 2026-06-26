// app/javascript/dpe_slider_logic.js
//
// Fonction PURE qui dérive la sélection de travaux correspondant à une cible
// DPE — modèle CASCADE MONOTONE PAR PRÉFIXES.
//
// ─── Modèle (Temps 3b-2 commit 2) ────────────────────────────────────────
// Deux entrées possibles :
//
//   1) Voie NOUVELLE — (prioriteGestes, combinaisons) :
//      - prioriteGestes : liste ordonnée de codes (gain EP décroissant
//        SPÉCIFIQUE au bien, calculée serveur par
//        PropertyDpeMatrixService).
//      - combinaisons : lookup { "<clé triée alphabétique>": {classe, ...} }.
//      Cascade : itérer k de 0 à N, prendre le préfixe prioriteGestes.slice(0, k),
//      construire la clé prefixe.slice().sort().join(",") — format exact de
//      PropertyDpeMatrixService#calculer_combinaisons (l. 116) — et chercher
//      le plus petit k tel que combinaisons[clé].classe ≤ targetClasse.
//
//   2) Voie HISTORIQUE — (dpeImpact, canonicalCodes) :
//      Forfait DPE_IMPACT scalaire. CONSERVÉE TEMPORAIREMENT pour ne pas
//      casser le site d'appel show.html.erb:722 pendant ce commit.
//      Sera SUPPRIMÉE au Temps 3b-2 commit 3 avec DPE_IMPACT.
//
// La voie nouvelle est privilégiée : si prioriteGestes et combinaisons sont
// fournies, on les utilise. Sinon on retombe sur la voie historique.
//
// ─── Garanties (les 4 propriétés P/Q/I/N préservées) ─────────────────────
//   1. CHEMIN-INDÉPENDANCE : deux appels avec mêmes args ⇒ même sélection.
//      Aucune lecture DOM, aucun état global, aucune horloge.
//   2. CASCADE MONOTONE EMBOÎTÉE : pour deux cibles tgt1 < tgt2 (tgt1 plus
//      ambitieuse), sélection(tgt1) ⊇ sélection(tgt2). Garantie par
//      construction (préfixes emboîtés) + monotonie de la matrice (testée
//      au Temps 3b-1 : ajouter un geste ne dégrade jamais la classe).
//   3. PURETÉ : entrées non mutées (slice() défensif sur prioriteGestes),
//      idempotent, déterministe.
//   4. INCLUSION STABLE de menuiseries : pour cibles ambitieuses qui
//      exigent le préfixe long, menuiseries est cochée — et son inclusion
//      est stable (jamais "parfois").
//
// ─── Note produit ────────────────────────────────────────────────────────
// L'ordre dans prioriteGestes est désormais SPÉCIFIQUE AU BIEN. Sur ID 69
// (1995 :partiel) le top 1 est isolation_murs (gain EP +95,9 sur ce bien).
// Sur Tilleuls (1962 :non_isole) le top 1 est chauffage (gain EP +128,0).
// La cascade reflète donc le LEVIER RÉEL du bien, pas un classement fixe.

function deriveSelectionForTarget({
  currentDpeIdx,
  targetIdx,
  // Voie nouvelle (matrice)
  prioriteGestes,
  combinaisons,
  // Voie historique (forfait) — sera supprimée au commit 3
  dpeImpact,
  canonicalCodes
}) {
  // targetIdx >= currentDpeIdx ⇒ aucune amélioration ⇒ sélection vide.
  if (targetIdx >= currentDpeIdx) {
    return { checked: [] };
  }

  // ─── Voie NOUVELLE : marche par préfixes de prioriteGestes ─────────
  if (Array.isArray(prioriteGestes) && combinaisons && typeof combinaisons === 'object') {
    return deriveViaMatrice({ targetIdx, prioriteGestes, combinaisons });
  }

  // ─── Voie HISTORIQUE : forfait dpeImpact (compat temporaire) ───────
  return deriveViaForfait({ currentDpeIdx, targetIdx, dpeImpact, canonicalCodes });
}

// ─── Cascade par préfixes de prioriteGestes + lookup matrice ────────────
// Itère k de 0 à N. Pour chaque k, construit la clé du préfixe (sort
// alphabétique côté JS = sort lexicographique côté Ruby pour des codes
// ASCII pur, ce qui est notre cas). Lookup la classe atteignable.
// Retourne le plus petit préfixe qui atteint la cible.
function deriveViaMatrice({ targetIdx, prioriteGestes, combinaisons }) {
  // Ordre canonique DPE : "ABCDEFG". indexOf("A") = 0 → meilleure classe.
  const ORDRE = "ABCDEFG";

  for (let k = 0; k <= prioriteGestes.length; k++) {
    // slice() — copie défensive (pureté : ne mute pas prioriteGestes)
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

// ─── Voie historique (forfait DPE_IMPACT) — à supprimer au commit 3 ─────
// Logique d'origine du Temps 3a : préfixe de la file canonique triée par
// impact décroissant + tie-break canonicalCodes stable.
// Conservée pour ne pas casser show.html.erb:722 pendant ce commit.
function deriveViaForfait({ currentDpeIdx, targetIdx, dpeImpact, canonicalCodes }) {
  const gainSouhaite = Math.max(0, currentDpeIdx - targetIdx);
  if (gainSouhaite === 0) {
    return { checked: [] };
  }

  const file = canonicalCodes
    .map(code => ({ code, impact: dpeImpact[code] || 0 }))
    .sort((a, b) => b.impact - a.impact);

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
//   variable globale accessible par les autres scripts de la page.
if (typeof module !== 'undefined' && module.exports) {
  module.exports = { deriveSelectionForTarget };
}
