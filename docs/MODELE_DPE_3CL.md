# Modèle DPE 3CL-inspiré — base de référence sourcée

> Spec de calcul du gain DPE pour Lauze. Remplace le barème forfaitaire `DPE_IMPACT`
> (chauffage=1.5, isolation=1.0…) par un modèle **physiquement fondé** sur la méthode
> réglementaire 3CL-DPE 2021 (ADEME / arrêté du 31 mars 2021).
>
> **Statut** : modèle 3CL-*inspiré*, pas un DPE opposable. Ambition = honnêteté
> conventionnelle (« cohérent avec la méthode officielle »), pas exactitude in situ —
> le vrai DPE 3CL est lui-même conventionnel et s'écarte de la conso réelle.
>
> **Date de calibrage** : juin 2026. ⚠️ Coefficients réglementaires datés — voir §6.

---

## 0. Principe — pourquoi le forfait était faux

Le barème actuel donne à chaque geste un nombre fixe de « classes gagnées ». C'est
structurellement faux pour deux raisons prouvées par la 3CL :

1. **Le DPE est un double seuil** : classe énergie (kWh/m²/an) ET classe carbone
   (kgCO₂/m²/an), et **la classe finale = la pire des deux**. Un forfait mono-nombre
   ne peut pas capturer ça (ex. une PAC améliore surtout le carbone, une isolation
   surtout l'énergie).
2. **Le gain d'un geste dépend du bâti et du point de départ.** Remplacer une chaudière
   fioul par une PAC = 2-3 classes (le carbone s'effondre). La même PAC sur un bien déjà
   électrique = quasi rien. Isoler des murs nus d'avant 1975 = énorme ; isoler des murs
   déjà corrects = marginal.

→ Le moteur doit calculer une **consommation** (énergie + carbone) à partir des
caractéristiques physiques, puis recalculer cette conso quand un geste modifie un poste.
La lettre est une **sortie**, pas une entrée forfaitaire.

---

## 1. Formule cœur (3CL — déperditions de l'enveloppe)

Source : arrêté 31/03/2021, annexe 1 (Légifrance, rt-re-batiment.developpement-durable.gouv.fr).

```
GV = DPmurs + DPplafonds + DPplanchers + DPbaies + DPportes + PT + DR
```

- `DPposte = Σ (b_i × S_i × U_i)` pour chaque paroi du poste
  - `S_i` = surface de la paroi déperditive (m²)
  - `U_i` = coefficient de transmission thermique (W/m².K) — **c'est ce qu'un geste change**
  - `b_i` = coefficient de réduction des déperditions (1 si donne sur l'extérieur ;
    < 1 si donne sur local non chauffé). Simplification raisonnable : b=1 extérieur,
    b≈0.8 plancher bas / garage.
- `PT` = ponts thermiques (W/K). Simplification : forfait ≈ 5-20 % de la somme des DP parois.
- `DR` = déperditions par renouvellement d'air (W/K). Dépend du débit de ventilation
  → c'est ce que la **VMC** modifie.

`GV` = déperdition totale par degré d'écart (W/K). Le besoin de chauffage annuel se
déduit de `GV × degrés-heures de la zone climatique` (voir §6, simplifié).

**Pour Lauze (modèle inspiré, pas DPE complet)** : on n'a pas besoin du besoin de
chauffage exact. On peut travailler en **proportion** : un geste qui fait chuter un
`U_i` réduit `GV` d'une fraction calculable, donc la conso d'autant, donc on reclasse.
Le cas de validation §7 sert à caler le facteur de proportionnalité.

---

## 2. Seuils des 7 classes DPE (logements > 40 m², < 800 m altitude)

Source : arrêté 31/03/2021 (concordance multiple : locservice, expert-batiment, hellowatt…).
**Règle d'or : classe finale = la PIRE des deux colonnes.**

| Classe | Énergie primaire (kWh/m²/an) | Carbone (kgCO₂/m²/an) |
|--------|------------------------------|------------------------|
| A      | ≤ 70                         | ≤ 6                    |
| B      | 71 – 110                     | 7 – 11                 |
| C      | 111 – 180                    | 12 – 30                |
| D      | 181 – 250                    | 31 – 50                |
| E      | 251 – 330                    | 51 – 70                |
| F      | 331 – 420                    | 71 – 100               |
| G      | ≥ 421                        | ≥ 101                  |

⚠️ **Logements ≤ 40 m²** : seuils spécifiques plus favorables depuis le 01/07/2024
(arrêté 25/03/2024). Le tableau ci-dessus ne s'applique PAS aux petites surfaces.
À gérer : si surface ≤ 40, brancher sur la grille petite surface (non détaillée ici,
à rechercher si le besoin se confirme).

---

## 3. U de départ — état « non isolé » par génération de bâti

Source : annexe 1 3CL + notice ADEME 08/10/2021 (valeurs par défaut).

| Paroi                          | U₀ non isolé (W/m².K) | Note source |
|--------------------------------|------------------------|-------------|
| Mur, construction **avant 1975** | **2,5**              | Umur0 par défaut (notice 2021, relève 2,0→2,5) |
| Mur ancien (pierre/terre/brique) | variable             | enduit isolant ≠ isolation |
| Plancher haut / combles non isolés | **2,5**            | Uph0 combles aménagés sous rampant |
| Plancher bas à entrevous isolant | 0,45                 | Upb0 |
| Simple vitrage (vertical/horizontal) | **5,8** (Ug)     | quelle que soit l'épaisseur du verre |

**Cas Lauze (14 rue des Tilleuls, maison 1962, classée F)** : mur ≈ 2,5 ; combles
probablement ≈ 2,5 si non isolés ; fenêtres simple vitrage ≈ 5,8. Point de départ
« passoire » cohérent avec le classement F observé.

Le `Min(Umur ; 2)` est appliqué dans la 3CL pour les calculs de déperdition (plafond).

---

## 3bis. Grille de rétro-déduction de l'état d'isolation par période de construction

> **Statut : hypothèse de modélisation Lauze, source `:deduit` (dernier recours).**
> S'applique uniquement quand aucune donnée d'isolation réelle n'est disponible
> (extraction DPE, description, saisie utilisateur). Toute source plus fiable
> l'écrase. La jauge devra l'afficher comme « supposée d'après l'année, à
> confirmer », jamais comme un fait.

Le §3 fournit les `U₀` « non isolé » par défaut, applicables sans nuance aux
bâtis < 1975. Mais l'application aveugle de ces `U₀` à *tout* bâti construit
avant 2000 fait déraper les bâtiments 1980-2000 : la RT 1974 puis la
RT 1988 imposaient déjà des seuils d'enveloppe que la valeur §3 ignore.

Le bien **ID 69** (Nancy, **1995**, classé **D** au DPE réel) illustre la
dette : au seuil binaire `<2000 = :non_isole` (Temps 2.5), le moteur le
calcule en F/G, écart -2 quelle que soit l'énergie testée. C'est exactement
ce que cette grille corrige.

### Table — état d'isolation par tranche de construction

| Période | RT applicable | Ubât typique (W/m².K) | Murs | Toiture | Menuiseries |
|---|---|---|---|---|---|
| **avant 1974**   | aucune                | ~1,8  | `:non_isole` | `:non_isole` | `:non_isole` (vitrage simple) |
| **1974 – 1982**  | RT 1974               | ~1,4  | `:non_isole` | `:non_isole` | `:non_isole` (vitrage simple) |
| **1983 – 1989**  | RT 1982 / RT 1988     | ~1,15 | `:partiel`   | `:partiel`   | `:non_isole` (simple → double émergent) |
| **1990 – 2000**  | RT 1988 / RT 2000     | ~0,95 | `:partiel`   | `:partiel`   | `:partiel` (double émergent) |
| **2001 – 2006**  | RT 2000               | ~0,8  | `:isole`     | `:isole`     | `:isole` (double standard) |
| **2007 – 2012**  | RT 2005               | ~0,75 | `:isole`     | `:isole`     | `:isole` (double performant) |
| **2013 et après**| RT 2012 / RE 2020     | ~0,4  | `:isole` (BBC) | `:isole`   | `:isole` (double ou triple) |

Bornes inclusives à droite (`year ≤ 1973`, `1974 ≤ year ≤ 1982`, etc.).
`year` inconnu → repli `:non_isole` partout (défaut conservateur).

### Notes

**Ubât vs Umur.** Le Ubât est un coefficient d'enveloppe **global** (somme
des déperditions parois rapportée à la SHON), pas un U_mur de paroi
individuelle. Il sert à *déduire l'état d'isolation* d'un bâti par période,
pas à fournir un `U` directement utilisable dans la formule §1 du moteur.
La table §3 reste la référence pour les `U₀` non isolé ; la table §4 pour
les `U` après travaux.

**État `:partiel` — zone grise.** Désigne les bâtis 1983-2000 où la
réglementation imposait une enveloppe meilleure que « rien » sans atteindre
les standards RT 2000+. Exemple concret observé en DB : bien ID 71 — « Bloc
béton creux avec isolation intérieure de 5 cm » → R_isolant ≈ 0,14 m².K/W,
R_paroi existante (parpaing 20 cm) ≈ 0,3-0,5, Rsi+Rse = 0,17, R total ≈ 0,67
→ **Umur ≈ 1,5 W/m².K**. Ni `:non_isole` (§3 = 2,5), ni `:isole` (§4 ≈ 0,26).

**Calage FIGÉ du moteur pour `:partiel`** (Temps 3a quater, `DpeEngineService` apprend `:partiel`) :

| Poste | Valeur figée | Justification |
|---|---|---|
| **Umur_partiel** | **1,5 W/m².K** | **Ancré sur le bien réel ID 71 ci-dessus.** Valeur OBSERVÉE, pas calibrée sur l'oracle. Conservative : 1,5 < UMUR_PLAFOND_CALCUL (2,0) donc le plafond §3 ne l'écrête pas — c'est volontaire. |
| **Uph_partiel** | **0,59 W/m².K** | Milieu géométrique entre §3 (UPH_NON_ISOLE = 2,5) et §4 (Uph_isolé ≈ 0,140 : R=7 + R_résiduelle 0,17) : √(2,5 × 0,140) ≈ 0,591. *Hypothèse Lauze, à affiner si on trouve un ancrage observé.* |
| **Uw_partiel** | **2,75 W/m².K** | Milieu géométrique entre §3 (UW_SIMPLE_VITRAGE = 5,8) et §4 (UW_DOUBLE_VITRAGE = 1,3) : √(5,8 × 1,3) ≈ 2,747. Cohérent avec « double émergent » des années 90 (Uw typiques 2,5-3,0). *Hypothèse Lauze, à affiner.* |
| **Upb_partiel** | **0,38 W/m².K** | Milieu géométrique entre §3 (UPB_DEFAUT = 0,45) et §4 (Upb_isolé ≈ 0,316 : R=3 + R_résiduelle 0,17) : √(0,45 × 0,316) ≈ 0,377. Note : l'écart partiel ↔ isolé est minime sur ce poste, le §3 prend déjà 0,45 « entrevous isolant » comme défaut. *Hypothèse Lauze, à affiner.* |

Test de monotonie automatisé dans `test/services/dpe_engine_service_test.rb` :
pour un bâti identique, EP / CO₂ / GV de l'état `:partiel` tombent strictement
entre `:non_isole` et `:isole`.

**Statut de la grille.** Hypothèse de dernier recours, source `:deduit` :
- s'efface devant toute donnée réelle (extraction ou saisie) ;
- n'écrase jamais une source de rang supérieur (même principe de hiérarchie
  que l'énergie au §5ter : `extrait > deduit > inconnue`) ;
- la jauge affichera la classe calculée avec un drapeau « supposée d'après
  l'année, à confirmer » quand l'état d'isolation provient de la grille.

**Test décisif — bien ID 69 (1995, classé D).**
- Avec le seuil binaire (Temps 2.5) : grille → `:non_isole` partout → moteur
  calcule **F/G** quelle que soit l'énergie → écart -2.
- Avec la grille §3bis + traduction temporaire `:partiel → :isole`
  (Temps 3a ter) : meilleure hypothèse = fioul → **D**, écart 0.
- Avec la grille §3bis + moteur qui gère nativement `:partiel`
  (Temps 3a quater, plus de traduction) : à mesurer dans
  `tmp/validate_dpe_engine.rb`. Le moteur applique Umur=1,5 / Uph=0,59 /
  Uw=2,75 directement. Classe attendue D (confirmation) ou E (acceptable
  ±1 vu que :partiel est plus conservateur que :isole). Si la classe
  redescend en F/G, le calage `:partiel` est mal posé.

### Sources

- **Ubât typique par période** : analyse comparative Choisir.com des performances
  des bâtis français selon la période de construction (déperditions enveloppe
  rapportées à la SHON).
- **Dates des RT** : Wikipédia « Réglementation thermique des bâtiments » +
  arrêtés ministériels —
  RT 1974 (arrêté 10/04/1974, premier choc pétrolier, premières exigences
  de limitation des déperditions) ;
  RT 1982 / RT 1988 (révisions progressives, double vitrage en généralisation
  fin années 80) ;
  RT 2000 (arrêté 29/11/2000, première RT globale, isolation systématique) ;
  RT 2005 (arrêté 24/05/2006, renforcement isolation et étanchéité) ;
  RT 2012 (label BBC, Cep_max ≈ 50 kWhEP/m²/an) ;
  RE 2020 (carbone-orienté, applicable depuis 01/01/2022).

---

## 4. U après travaux — déduits des résistances réglementaires (R)

`U = 1 / (R_isolant + R_paroi_résiduelle)`. R_paroi résiduelle ≈ 0,3–0,5 m².K/W.
Source R minimaux (cellulose-igloo, captain-renov, batisec — éligibilité MaPrimeRénov/CEE) :

| Geste                       | R réglementaire min (m².K/W) | U après ≈ (W/m².K) |
|-----------------------------|------------------------------|---------------------|
| Isolation murs ITI          | ≥ 3,7                        | ≈ 0,24              |
| Isolation murs ITE          | ≥ 4,4                        | ≈ 0,21              |
| Isolation combles perdus    | ≥ 7                          | ≈ 0,13              |
| Isolation rampants toiture  | ≥ 6                          | ≈ 0,16              |
| Isolation plancher bas      | ≥ 3                          | ≈ 0,29              |
| Remplacement fenêtres (double vitrage perf.) | Uw ≤ 1,3    | **1,3** (Uw direct) |

→ Isoler un mur 1962 : `Umur` passe de **2,5 → ~0,24** (÷10 sur ce poste).
→ Changer les fenêtres : `Uw` passe de **5,8 → 1,3** (÷4,5 sur ce poste).
C'est le **vrai** gain, posté par poste — pas un forfait.

---

## 5. Systèmes de chauffage — le levier carbone (souvent décisif)

Le changement de système n'agit pas (ou peu) sur les déperditions `GV`, mais sur le
**rendement** et surtout sur le **facteur carbone de l'énergie**. C'est lui qui fait
basculer l'étiquette climat.

### 5a. Facteurs énergie primaire (conso finale → primaire)
Source : FAQ DPE gouv (rt-re-batiment), arrêté 13/08/2025.

| Énergie       | Coef. énergie primaire |
|---------------|------------------------|
| **Électricité** | **1,9** (depuis 01/01/2026 ; était 2,3 avant) |
| Gaz naturel   | 1                      |
| Fioul         | 1                      |
| Bois          | 1 (parfois 0,6 selon contexte politique — à vérifier) |

### 5b. Facteurs carbone (contenu CO₂ par kWh d'énergie finale)
Source : Wikipédia DPE (analyse cycle de vie) + arrêté ; locservice (élec 79 g).

| Énergie       | gCO₂éq / kWh | kgCO₂ / kWh |
|---------------|-------------|-------------|
| **Bois**      | ~13         | 0,013       |
| **Électricité** | ~79       | 0,079       |
| **Gaz naturel** | ~234      | 0,234       |
| **Fioul**     | ~300        | 0,300       |

→ **Conséquence clé** : passer fioul → PAC (élec) fait chuter le carbone de
0,300 à 0,079 kg/kWh, ET divise la conso finale par le COP de la PAC (~3).
Double effet → 2-3 classes. C'est pourquoi « remplacement chauffage » ne peut pas
valoir un forfait fixe : sur une maison déjà électrique, l'effet carbone est nul.

---

## 5bis. Du GV à la conso — VOIE ABSOLUE (besoin de chauffage réel)

Source : arrêté 17/10/2012 + annexe 3CL-DPE 2021 (Légifrance) ; calibrage croisé Organilog.

La 3CL ne s'arrête pas à GV (W/K). Elle calcule un **besoin de chauffage annuel** en
multipliant les déperditions par les degrés-heures de la zone climatique, moins les
apports gratuits, divisé par les rendements du système.

### Chaîne de calcul
```
GV (W/K)                        ← §1, somme des déperditions
  ↓ × degrés-heures zone, − apports gratuits (soleil + occupation)
Besoin chauffage Bch (kWh)      ← Bch = BV × DH   (BV dérivé de GV)
  ↓ ÷ (Rg × Re × Rd × Rr)  [Rg = COP pour PAC]
Conso finale chauffage (kWh)
  ↓ + conso ECS + auxiliaires + (clim/éclairage négligeables au 1er jet)
Conso finale totale (kWh)
  ↓ × facteur énergie primaire (§5a : élec 1,9 ; fossiles/bois 1)
Conso énergie primaire (kWhEP) → ÷ surface → kWhEP/m²/an → CLASSE ÉNERGIE (§2)

  ET en parallèle :
Conso finale totale × facteur carbone (§5b) → ÷ surface → kgCO₂/m²/an → CLASSE CARBONE (§2)

CLASSE FINALE = pire(classe énergie, classe carbone)
```

### Degrés-heures par zone climatique (base 14, arrêté 17/10/2012)

| Zone | Tmoy (°C) | DH14   | Exemples              |
|------|-----------|--------|-----------------------|
| **H1** | 6,58    | **42030** | **Nancy**, Paris, Strasbourg, Nord-Est |
| H2   | 8,08      | 33300  | Rennes, Bordeaux, Ouest/Sud-Ouest |
| H3   | 9,65      | 22200  | Marseille, littoral méditerranéen |

→ **Nancy = zone H1**, la plus froide → le plus de degrés-heures → besoin de chauffage
le plus élevé. Un même bien est ~1 à 2 classes moins bien classé en H1 qu'en H3.
Référence : base de calcul des besoins = écart cumulé sous 19 °C de consigne (apports
internes portent les 18 °C du chauffage à 19 °C).

### Rendements système (conso = besoin ÷ rendements)
- Chaudière gaz condensation : Rg ≈ 0,90–1,0 (sur PCI)
- Chaudière fioul ancienne : Rg ≈ 0,70–0,80
- Convecteurs électriques : Rg ≈ 1,0 (mais ×1,9 en primaire !)
- **PAC air/eau : Rg = COP ≈ 3** (besoin ÷ 3 → effondre la conso)
- Re × Rd × Rr (émission/distribution/régulation) ≈ 0,85–0,95 combiné

### Formule express de calibrage (Organilog — pour test de cohérence, ±25 %)
```
E (kWh/an) = G × V × DJU × 24 / 1000
```
- `G` = coef. déperdition volumique (W/m³.K) : passoire 2,0–2,8 ; moyenne 1,2–1,5 ;
  RT2005 ~1,0 ; BBC 0,4–0,7 ; passif 0,2–0,4
- `V` = volume habité (m³) = surface × hauteur sous plafond (~2,5 m)
- `DJU` zone H1 ≈ 2400–2600
→ sert à **vérifier** que le moteur 3CL ne sort pas un chiffre aberrant. Pas la méthode
principale, mais un garde-fou indépendant.

### Hiérarchie des pertes (garde-fou sur le poids des gestes)
Toit 25–30 % · Murs 20–25 % · Renouvellement d'air 20–25 % · Fenêtres 10–15 % ·
Plancher bas 7–10 % · Ponts thermiques 5–10 %.
→ Si le moteur fait peser les fenêtres à 40 % ou la toiture à 5 %, il y a un bug.
Impact attendu des gestes sur G : toiture R≥7 réduit G de 0,3–0,5 ; ITE murs R≥3,7
réduit de 0,2–0,4 ; fenêtres Uw≤1,3 réduit de 0,1–0,2 ; VMC double flux 0,1–0,2.

---

## 5ter. Valeurs de calage du moteur Lauze (compléments au §5bis)

Le §5bis donne la chaîne de calcul et les fourchettes réglementaires. Trois
familles de valeurs ne sont pas figées par la 3CL : (a) les surfaces de parois
par défaut quand non saisies, (b) les paramètres de simplification du modèle,
(c) le forfait ECS. Cette section les fige pour le moteur, **chacune justifiée
par la physique ou marquée explicitement hypothèse de modélisation Lauze**.

Convention : valeurs **réglementaires/normatives en gras** ; *hypothèses Lauze
en italique* — toute modification doit être tracée ici.

### 5ter.a — Surfaces de parois par défaut

Quand l'utilisateur ne fournit pas une surface, on l'estime à partir de la
surface habitable et du nombre de niveaux, par une géométrie de **maison
carrée**. *Hypothèse de modélisation Lauze* — la 3CL réglementaire utilise des
règles de saisie par défaut analogues quand les surfaces ne sont pas relevées.

| Poste | Formule | Pour 120 m² / 2 niveaux |
|---|---|---|
| Emprise au sol | `S_sol = S_hab / N` | 60 m² |
| Périmètre | `P = 4 × √S_sol` (maison carrée) | 30,98 m |
| Hauteur sous plafond | **2,5 m** standard | 2,5 m |
| Surface murs bruts | `S_mur_brute = P × N × 2,5` | 154,9 m² |
| Surface fenêtres | `S_fen = S_hab / 6` (ratio RT 1/6e) | 20 m² |
| Surface murs nets | `S_mur = S_mur_brute − S_fen` | 134,9 m² |
| Surface toiture combles perdus | `S_toit = S_sol × 1,0` (défaut) | 60 m² |
| Surface toiture combles aménagés rampants | `S_toit = S_sol × 1,15` (pente ~30°) | 69 m² |
| Surface plancher bas | `S_pb = S_sol` | 60 m² |

Si un poste est saisi explicitement, la valeur fournie remplace le défaut
(ex. cas oracle §7 : `S_mur = 80`, `nombre_fenetres = 8` → `8 × 1,5 = 12 m²`).
**Une fenêtre par défaut = 1,5 m²** (fenêtre ancienne typique).

**Niveaux par défaut : N = 2** (maison standard).

### 5ter.b — Renouvellement d'air (DR)

Formule physique standard (RT / Th-BCE) :

```
DR = 0,34 × Qv       (W/K)
Qv = n × V_hab       (m³/h)
```
- **0,34** = ρ_air × cp_air / 3600 (constante physique)
- **n** = taux de renouvellement (vol/h)
- **V_hab** = S_hab × hauteur sous plafond

Valeurs de `n` par état de ventilation :

| Ventilation | n (vol/h) | Justification |
|---|---|---|
| `:aucune_vmc` (défaut, bâti ancien) | *1,0* | Borne haute des valeurs conventionnelles : RT 2005 prend 0,6 mais les bâtis < 1975 ont des défauts d'étanchéité réels mesurés à 1,0–1,5. *Hypothèse Lauze* cohérente avec la cible §5bis « renouv. air = 20–25 % du GV » sur une passoire. |
| `:vmc_simple_flux` | 0,5 | Débit hygiénique RT pré-2012. |
| `:vmc_double_flux` | 0,15 | Débit hygiénique − récupération ~75 %. |

### 5ter.c — Paramètres de simplification

| Paramètre | Valeur | Justification |
|---|---|---|
| **R_paroi résiduelle** (formule §4 : `U = 1/(R_isol + R_rés)`) | **0,17 m².K/W** | Résistances superficielles d'échange `Rsi + Rse = 0,13 + 0,04` pour paroi verticale, **norme NF EN ISO 6946**. Constante physique de manuel thermique, *pas* un calibrage. Le §4 cite une fourchette 0,3–0,5 qui inclut en plus la résistance de la paroi existante (parpaing/brique) ; on s'en tient ici aux résistances superficielles pures (légèrement conservatif : U_ITI = 0,258 au lieu de 0,238 pour R=3,7). |
| Forfait **ponts thermiques** PT (§1 fourchette 5–20 %) | *12 % des DP parois* | Milieu de fourchette. Cohérent avec §5bis cible « PT = 5–10 % du GV total » : 12 % des parois → ~8–10 % du GV total. |
| **Coefficient d'apports gratuits** (soleil + occupation, §5bis « − apports gratuits ») | *0,95* | `Bch = 0,95 × GV × DH14 / 1000`. *Hypothèse Lauze* — la 3CL fine utilise un coefficient d'utilisation `X^a/(X^a−1)` dépendant du rapport apports/déperditions, non implémenté. 0,95 = borne basse des apports utiles, cohérent passoire mal orientée. |
| **Rerd** = émission × distribution × régulation (§5bis fourchette 0,85–0,95) | *0,85* | Borne basse — *hypothèse Lauze* cohérente avec le parc cible (passoires < 1975 = installations vieillissantes, radiateurs surdimensionnés, régulation imparfaite). Bumper à 0,90 pour installation récente / PAC moderne serait défensible et modifie ~6 % la conso finale. |

### 5ter.d — ECS forfait (eau chaude sanitaire)

§9 autorise « ECS estimé ou négligé au 1er jet ». On choisit un **forfait
en kWh/m²/an d'énergie finale**, justifié par le besoin physique annuel.

**Besoin utile ECS** (calcul conventionnel) :

```
B_ECS = ρ·c · V_jour · ΔT · 365 / 1000   (kWh/an utile)
```

- **ρ·c** = 1,162 Wh/L.K (eau)
- **V_jour** = N · v_per_pers  avec  **v_per_pers = 50 L/p/j** (conv. 3CL)
- **ΔT** = 35 K (eau froide 12,5 °C → eau chaude 47,5 °C, conv. 3CL)
- **N = 2 occupants conventionnels** — *hypothèse Lauze* (foyer adultes,
  composition non interrogée). La 3CL réglementaire prend `N = 0,025 × S_hab`
  donnant ~3 pour 120 m². On retient la borne basse pour ne pas surcharger
  l'EP des biens fioul/gaz au-delà de ce que les apports utiles compensent.

→ `B_ECS = 1,162 × 100 × 35 × 365 / 1000 ≈ 1 485 kWh utile/an` (indépendant
de S_hab → le besoin/m² *décroît* avec la surface, comportement attendu :
un grand logement n'a pas besoin de plus d'ECS qu'un petit pour le même foyer).

**Conso finale ECS** = `B_ECS ÷ rendement combiné` (génération × stockage/distribution) :

| Énergie | Rendement combiné | Conso ECS / logement | **Conso ECS / m² (S=120)** |
|---|---|---|---|
| `:gaz`, `:fioul`, `:bois` | *0,82* (ballon ECS performant ou cumulus élec séparé) | 1 815 kWh EF | **15 kWh/m²/an EF** |
| `:electricite` | *0,73* (cumulus standard 200 L, pertes stockage 0,85) | 2 035 kWh EF | **17 kWh/m²/an EF** |
| `:pac` | *2,13* = COP_ECS 2,5 × pertes 0,85 (CET thermodynamique) | 697 kWh EF | **7 kWh/m²/an EF** |

→ `ECS_FORFAIT_EF = {gaz: 15, fioul: 15, bois: 15, electricite: 17, pac: 7}` kWh/m²/an EF.

*Limite assumée :* le forfait est calé sur S_hab = 120 m². Pour les autres
surfaces, le besoin réel est plus ou moins surestimé/sous-estimé — ce que la
3CL réglementaire évite en recalculant `B_ECS` à partir de `N(S_hab)`. C'est
une simplification §9 — à affiner si le moteur est étendu à d'autres typologies.

### 5ter.e — Récapitulatif machine-lisible

```ruby
# Réglementaires / normatives — MAJ avec §6 si évolution arrêté
DH14[:h1] = 42_030 ; DH14[:h2] = 33_300 ; DH14[:h3] = 22_200    # §5bis
RG = {gaz: 0.95, fioul: 0.75, electricite: 1.0, bois: 0.75, pac: 3.0}   # §5bis
FACTEUR_EP = {electricite: 1.9, pac: 1.9, gaz: 1.0, fioul: 1.0, bois: 1.0}  # §5a
FACTEUR_CO2 = {gaz: 0.234, fioul: 0.300, electricite: 0.079,
               pac: 0.079, bois: 0.013}                          # §5b
UMUR_NON_ISOLE = 2.5 ; UPH_NON_ISOLE = 2.5
UPB_DEFAUT = 0.45 ; UW_SIMPLE_VITRAGE = 5.8                      # §3
UMUR_PLAFOND_CALCUL = 2.0                                        # §3 Min(Umur ; 2)
R_ITI_MIN = 3.7 ; R_COMBLES_PERDUS_MIN = 7.0
R_PLANCHER_BAS_MIN = 3.0 ; UW_DOUBLE_VITRAGE = 1.3               # §4
B_EXTERIEUR = 1.0 ; B_PLANCHER_BAS = 0.8                         # §1
R_RESIDUELLE_PAROI = 0.17                                        # NF EN ISO 6946
CONST_DR = 0.34                                                  # ρ·c air / 3600

# Hypothèses Lauze (§5ter) — modifiables avec traçabilité ici
COEF_PT             = 0.12
N_VENTILATION       = {aucune_vmc: 1.0, vmc_simple_flux: 0.5, vmc_double_flux: 0.15}
COEF_APPORTS        = 0.95
RERD                = 0.85
ECS_FORFAIT_EF      = {gaz: 15, fioul: 15, bois: 15, electricite: 17, pac: 7}
NIVEAUX_DEFAUT      = 2
HAUTEUR_SOUS_PLAFOND_DEFAUT = 2.5
M2_PAR_FENETRE_DEFAUT = 1.5
RATIO_TOITURE_PLATE = 1.0  ;  RATIO_TOITURE_RAMPANTS = 1.15
RATIO_SURFACE_FENETRES = 1.0 / 6
```

---

## 6. ⚠️ Coefficients datés — à maintenir

- **Élec énergie primaire = 1,9** depuis le 01/01/2026 (était 2,3). Arrêté 13/08/2025.
  Coder en constante datée, pas en dur perdu dans le code.
- Seuils petites surfaces (≤ 40 m²) : grille spécifique depuis 01/07/2024.
- Bonus « sortie de passoire » MaPrimeRénov supprimé depuis juin 2025 (impacte les
  aides, pas le DPE — mais pertinent pour la cohérence du parcours Lauze).
- Zones climatiques (H1/H2/H3) : la 3CL utilise des degrés-heures par zone. Nancy = H1
  (Nord-Est, plus froid). Un même bien est mieux classé en H3 (Sud) qu'en H1.
  → si le modèle reste proportionnel (§1), la zone peut être un facteur correctif global.

---

## 7. Cas de validation (oracle)

Source : quali-ti-plaque (guide MaPrimeRénov murs 2026). **Si le moteur ne reproduit
pas ce résultat, il est mal calé.**

> Maison **120 m²**, murs **80 m²** sur 2 façades, combles, **8 fenêtres anciennes**.
> Travaux : ITI laine de verre 14 cm (**R=4,35**, soit Umur ~0,21) + combles perdus
> 30 cm laine soufflée (**R=7,5**, soit Uph ~0,13) + menuiseries double vitrage
> (**Uw ≤ 1,3**).
> Résultat : **passage de F à D** (gain 2 classes).

Test cible : nourrir le moteur avec ces entrées → il doit sortir **F → D**.

---

## 8. Postes Lauze → variables 3CL (mapping)

| Geste Lauze (code)        | Agit sur          | Variable modifiée        |
|---------------------------|-------------------|--------------------------|
| `isolation_murs`          | DPmurs            | Umur : 2,5 → ~0,24       |
| `isolation_toiture`       | DPplafonds        | Uph : 2,5 → ~0,13        |
| `isolation_plancher_bas`  | DPplanchers       | Upb : → ~0,29            |
| `menuiseries`             | DPbaies           | Uw : 5,8 → 1,3           |
| `vmc`                     | DR (renouvel. air) | débit ventilation ↓     |
| `chauffage` (PAC/décarboné) | énergie + carbone | facteur EP + facteur CO₂ |
| `chauffe_eau`             | conso ECS         | rendement + énergie ECS  |

---

## 9. Ce qu'on NE fait PAS (limites assumées)

- Pas de degrés-heures mensuels par zone (3CL complet) → facteur climatique global.
- Pas de ponts thermiques par liaison → forfait % des DP parois.
- Pas de rendements de génération détaillés par modèle de chaudière → valeurs typiques.
- Pas de calcul ECS / éclairage / auxiliaires fin → estimés ou négligés au 1er jet.
- **ECS calé sur S_hab = 120 m²** (§5ter.d) — biais ±10 % sur autres surfaces.
- **Instabilité aux seuils**. Le cas oracle §7 (F→D) se joue sur l'étiquette
  carbone à ~1 kgCO₂/m²/an du seuil D (32,1 calculé vs seuil bas 31). C'est
  étroit. Ce moteur est un *estimateur de cohérence*, pas un DPE de précision :
  un bien réel dont la conso EP ou CO₂ se trouve à moins de ±5 % d'un seuil
  doit être traité comme **indéterminé entre les deux classes** (la jauge le
  signalera explicitement). Cette propriété est intrinsèque à toute méthode
  3CL simplifiée — le vrai DPE 3CL l'a aussi, atténuée par un plus grand
  nombre de paramètres.
- **Pas opposable.** C'est un estimateur de cohérence, pas un DPE réglementaire.

→ Ces limites sont **documentées et défendables**. Le vrai DPE est lui-même
conventionnel. L'objectif Lauze : que la jauge ne promette jamais une classe que les
gestes ne peuvent pas atteindre — fondé sur la physique réelle, pas sur un forfait.

---

## 10. Sources principales

- Arrêté 31/03/2021, annexe 1 (méthode 3CL-DPE 2021) — rt-re-batiment.developpement-durable.gouv.fr ; Légifrance
- Notice modificative 08/10/2021 (Umur 2,0→2,5) — ecologie.gouv.fr
- FAQ DPE coef. élec 2,3→1,9 (arrêté 13/08/2025) — rt-re-batiment.developpement-durable.gouv.fr
- Seuils classes : concordance locservice / expert-batiment / hellowatt / selectra
- Facteurs carbone : Wikipédia DPE (ACV) ; bois 13 / gaz 234 / fioul 300 gCO₂/kWh
- R réglementaires rénovation : cellulose-igloo, captain-renov, batisec (MaPrimeRénov/CEE)
- Cas validation F→D : guide MaPrimeRénov murs 2026 (quali-ti-plaque)
- Résistances superficielles Rsi/Rse paroi verticale (§5ter.c) : norme **NF EN ISO 6946** — calcul de la résistance thermique des composants de bâtiment
- Débit de renouvellement d'air (§5ter.b) : RT 2005 / Th-BCE (CSTB) — taux conventionnels par type de ventilation
- Besoin ECS conventionnel (§5ter.d) : capacité thermique de l'eau ρ·c = 1,162 Wh/L.K (constante physique) ; volume 50 L/p/j et ΔT 35 K conv. 3CL
