# Réconciliation aides ALEC Nancy 2026 ↔ calcul Lauze

**Objet.** Comparer le calcul d'aides en production (`AidCalculatorService`
+ `LocalAidCalculator`) aux fiches officielles de l'ALEC Nancy 2026 :

- `alec-nancy-grands-territoires-2-aides-financieres-1-1.pdf` → parcours **Par geste**
- `alec-nancy-grands-territoires-2-aides-financieres-.pdf`   → parcours **Rénovation d'ampleur**
- `alec-nancy-grands-territoires-2-aides-financieres-1-2.pdf` → parcours **Copropriété**

**Aucune logique de calcul n'a été modifiée** : ce document est purement
analytique.

Statuts utilisés dans les tableaux :
- ✅ **conforme** — la valeur PDF est implémentée correctement
- ⚠️ **écart** — la valeur PDF existe en code mais avec un chiffre / une logique différente
- ❌ **manquant** — le dispositif PDF n'est pas implémenté du tout
- ❓ **à clarifier** — implémentation ambiguë (à confirmer avec l'ALEC ou côté code)

---

## 0. Architecture observée — qui calcule quoi ?

| Couche | Fichier | Ce qui s'y passe |
|---|---|---|
| Calcul national + Grand Nancy en dur | `app/services/aid_calculator_service.rb` | Toutes les constantes (`MPR_TAUX_2026`, `MPR_PAR_GESTE_FORFAITS`, `CEE_FORFAITS`, `ECO_PTZ_*`, `GN_ISOLATION_*`, `GN_RENO_GLOBALE_TAUX`) et tout le routage Ampleur / Par geste. |
| Calcul aides locales en data | `app/services/local_aid_calculator.rb` + table `local_aid_schemes` | Boucle sur `LocalAidScheme.currently_valid` et persiste un `LocalAidResult` par bien. |
| Catalogue déclaratif | `db/seeds_local_aids.rb` | Crée 4 `AidRule` (`mpr_parcours_accompagne`, `eco_ptz`, `grand_nancy_isolation`, `grand_nancy_renovation_globale`). |
| UI principale | `app/views/properties/show.html.erb` + `_aid_result.html.erb` | Lit `@aid_result` produit par `AidCalculatorService` dans `PropertiesController#show` (l. 42-45). |
| UI aides locales | `app/views/properties/_local_aids.html.erb` | Lit `property.local_aid_results` (sortie de `LocalAidCalculator`). |

**Constat #1 — laquelle alimente l'UI ?** L'écran de résultats est piloté
**à 100 %** par `AidCalculatorService` (`show.html.erb:33-47`,
`_aid_result.html.erb:41-60`). Le partial `_local_aids.html.erb` n'apparaît
qu'**en plus**, et uniquement si `property.local_aid_results` contient des
lignes éligibles.

**Constat #2 — `LocalAidScheme` n'est jamais seedé.** Aucun fichier `db/seeds*`
ne crée de `LocalAidScheme` (vérifié par `grep "LocalAidScheme.create"`).
Conséquence : en production `LocalAidScheme.currently_valid` retourne
probablement une collection vide, `LocalAidCalculator#call` ne crée rien,
et `_local_aids.html.erb` ne rend rien. **À confirmer en prod** — si la table
contient des données héritées d'avant le pivot vers `AidCalculatorService`,
il y a un risque d'incohérence (deux montants pour la même aide Grand Nancy).

**Constat #3 — duplication Grand Nancy.** Grand Nancy est modélisé deux fois :
en dur dans `AidCalculatorService` (`GN_ISOLATION_MODESTE/SUPERIEUR`,
`GN_RENO_GLOBALE_TAUX`), **et** comme `AidRule` dans `db/seeds_local_aids.rb`
(`grand_nancy_isolation`, `grand_nancy_renovation_globale`), **et** comme
schéma `LocalAidScheme` (table + admin controller `app/controllers/admin/local_aid_schemes_controller.rb`).

**Constat #4 — dette structurelle `AidRule`.** La table `aid_rules` a des
colonnes riches (`conditions jsonb`, `amount_type`, `amount_value`,
`amount_max`, `amount_min`, `amount_base`, `amount_notes`) — mais
`AidCalculatorService` ne lit que `slug`, `name`, `source_label`,
`valid_until`. Tout le reste est mort : les règles métier vivent dans le
code Ruby, pas dans la donnée. Le fichier `aid_rule.rb` est même réduit à
`class AidRule < ApplicationRecord; end`.

---

## 1. Plafonds RFR 2026 — fondation commune

### Valeur PDF (identique sur fiche par geste et fiche ampleur)

| Personnes | TM (BLEU) | M (JAUNE) | I (VIOLET) | S (ROSE) |
|---:|---:|---:|---:|---:|
| 1 | ≤ 17 363 € | ≤ 22 259 € | ≤ 31 185 € | > 31 185 € |
| 2 | ≤ 25 393 € | ≤ 32 553 € | ≤ 45 842 € | > 45 842 € |
| 3 | ≤ 30 540 € | ≤ 39 148 € | ≤ 55 196 € | > 55 196 € |
| 4 | ≤ 35 676 € | ≤ 45 735 € | ≤ 64 550 € | > 64 550 € |
| 5 | ≤ 40 835 € | ≤ 52 348 € | ≤ 73 907 € | > 73 907 € |
| Pers. supp. | + 5 151 € | + 6 598 € | + 9 357 € | + 9 357 € |

### Implémentation actuelle

| Dispositif | Valeur ALEC 2026 | Implémentation actuelle | Statut | Action |
|---|---|---|---|---|
| Mapping RFR → `income_bracket` (fonction du nombre de personnes du foyer) | Tableau complet ci-dessus | **Inexistant.** L'utilisateur choisit `income_bracket` directement via 4 boutons radio dans `_aid_result.html.erb:16-35`. Aucune dérivation depuis un RFR saisi, ni du nombre de personnes du ménage (le modèle `Property` n'a même pas de colonne `household_size`). | ❌ manquant | Avant vendredi : corriger les sous-labels (voir ligne suivante). Chantier de fond : ajouter `household_size` sur `Property` + un service `IncomeBracketResolver.call(rfr, household_size)`. |
| Sous-labels affichés à l'utilisateur sous chaque bouton | Variables avec le nombre de personnes (cf. tableau) | `_aid_result.html.erb:19-23` affiche des seuils figés et incorrects : « < 21 000 €/an », « 21 000 – 30 000 € », « 30 000 – 45 000 € », « > 45 000 € ». Ces seuils ne correspondent à aucune ligne du tableau ALEC et **classent un couple modeste en intermédiaire**. | ⚠️ écart | Avant vendredi : retirer les sous-labels, ou les remplacer par « selon votre nombre de personnes au foyer (cf. ALEC) ». |

---

## 2. Parcours « Par geste »

### 2.1 MaPrimeRénov' Par geste

| Dispositif | Valeur ALEC 2026 | Implémentation actuelle | Statut | Action |
|---|---|---|---|---|
| Éligibilité | Tous **sauf revenus supérieurs**, propriétaires occupants/bailleurs (hors SCI), logement > 15 ans | `MPR_PAR_GESTE_FORFAITS["superieur"] = {}` (`aid_calculator_service.rb:144`) + check `construction_year` (l.351). Pas de check hors-SCI (`Property` n'a pas le concept). | ✅ conforme (avec réserve SCI) | Documenter que les SCI ne sont pas filtrées. |
| Forfaits unitaires MPR par geste (€ par équipement / €/m²) | Le PDF ALEC ne détaille pas les forfaits, il renvoie sur `maprimerenov.gouv.fr` | `MPR_PAR_GESTE_FORFAITS` (l.82-145) : barème complet TM/M/I conforme aux fiches ANAH 01/03/05 référencées en commentaire (PAC air/eau 5000/4000/3000 €, PAC géo 11000/9000/6000 €, etc.) | ❓ à clarifier | Demander à l'ALEC une fiche détaillée par équipement, ou pointer la source ANAH dans le code. |
| Cap cumul MPR+CEE en par geste (% TTC) | Mentionné dans les fiches ANAH (90/75/60 %) | `MPR_PAR_GESTE_CUMUL_CAP` (l.235-240) : 90/75/60/100 % | ✅ conforme | — |

### 2.2 Certificats d'Économie d'Énergie (CEE)

| Dispositif | Valeur ALEC 2026 | Implémentation actuelle | Statut | Action |
|---|---|---|---|---|
| Principe | Cumulable avec MPR par geste et éco-PTZ, **non cumulable avec MPR Accompagné** | `CEE_FORFAITS` additionnés au MPR par geste (`calculate_mpr_par_geste_and_cee`, l.474-558). En parcours accompagné le code **n'ajoute pas** de ligne CEE séparée (cf. commentaire l.410-414). | ✅ conforme | — |
| Forfaits unitaires CEE | Le PDF ALEC est silencieux côté maison individuelle (juste « les montants varient selon l'organisme »). Côté copro il donne des fourchettes (8-10 €/m² murs, 6-10 €/m² toiture, 6-8 €/m² plancher bas, 80-150 €/log VMC) | `CEE_FORFAITS` (l.149-231) : barème complet par profil avec ITE 15/12/12/12 €/m², ITI 9/7/7/7 €/m², rampants 12/11/11/11 €/m², etc. Les commentaires (l.150-155) reconnaissent que ces valeurs sont des estimations cohérentes en interne, pas un arrêté officiel. | ❓ à clarifier | Chantier de fond : sourcer plus précisément ou afficher une fourchette plutôt qu'un point. |

### 2.3 Aides Grand Nancy « Plan Climat » (isolation €/m²)

**PDF (page 2 de la fiche par geste)** — forfaits pour les **derniers gestes d'isolation** permettant d'atteindre au minimum l'étiquette C, **hors parcours accompagné** :

| Poste | Modestes / Très modestes | Intermédiaires / Supérieurs |
|---|---:|---:|
| ITE (murs ext.) | 40 €/m² | 30 €/m² |
| ITI (murs int., si ext. impossible) | 10 €/m² | 5 €/m² |
| Sarking (toiture ext.) | 50 €/m² | 40 €/m² |
| Combles perdus | 10 €/m² | 5 €/m² |
| Toiture terrasse | 40 €/m² | 30 €/m² |
| Plancher bas | 15 €/m² | 10 €/m² |

| Dispositif | Valeur ALEC 2026 | Implémentation actuelle | Statut | Action |
|---|---|---|---|---|
| Forfaits €/m² par poste, par tranche | cf. tableau ci-dessus | `GN_ISOLATION_MODESTE` (l.281-288) et `GN_ISOLATION_SUPERIEUR` (l.290-297) : **valeurs strictement identiques** au PDF. | ✅ conforme | — |
| Restriction maisons individuelles | « propriétaires occupants ou bailleurs d'**une maison individuelle** » | `maison_individuelle?` testé (l.602, l.741-743) | ✅ conforme | — |
| Cible mini étiquette C | « atteindre à minima une étiquette énergie C » | Check `dpe_target ∈ {A,B,C}` (l.609) | ✅ conforme | — |
| Restriction hors parcours accompagné | « hors Parcours Accompagné de MaPrimeRénov' » | `return if eligible_parcours_accompagne?` (l.606) | ✅ conforme | — |
| Condition : solliciter les CEE auprès de la Métropole | Mentionné en bas du paragraphe Plan Climat | Pas tracé dans le calcul (note `Cumulable avec CEE Primes énergie Grand Nancy uniquement.` en libre dans `note:`, l.647) | ❓ à clarifier | Suffisant pour vendredi (info dans la note). Chantier de fond : règle dédiée. |

### 2.4 Prime Air Bois (Grand Nancy)

| Dispositif | Valeur ALEC 2026 | Implémentation actuelle | Statut | Action |
|---|---|---|---|---|
| Prime Air Bois | 1 500 € ou 2 500 € selon revenus, remplacement d'un appareil bois antérieur à 2005, **non cumulable avec CEE** | **Absente.** Aucune occurrence dans le code. | ❌ manquant | Voir Priorités. |

### 2.5 ComCom Pays du Sel et du Vermois

| Dispositif | Valeur ALEC 2026 | Implémentation actuelle | Statut | Action |
|---|---|---|---|---|
| Aide ComCom Sel et Vermois | 25 % HT travaux isolation, plafond 1 000 € ou 1 500 € selon RFR ; 25 % HT EnR, plafond 2 000 € | **Absente.** Aucune occurrence (le périmètre Grand Nancy s'arrête à la liste de communes du module `GrandNancy`). | ❌ manquant | Voir Priorités. |

### 2.6 ComCom Seille et Grand Couronné (parcours par geste)

| Dispositif | Valeur ALEC 2026 | Implémentation actuelle | Statut | Action |
|---|---|---|---|---|
| Aide ComCom Seille et Grand Couronné « par geste » | Bouquet de travaux (≥ 2 gestes dont un d'isolation) : 850 € à 1 250 € selon revenus | **Absente.** | ❌ manquant | Voir Priorités. |

### 2.7 Éco-PTZ (parcours par geste)

| Dispositif | Valeur ALEC 2026 | Implémentation actuelle | Statut | Action |
|---|---|---|---|---|
| Grille montants | « va de 7 000 € à 30 000 € en fonction des actions » | `ECO_PTZ_GRILLE` (l.270-274) : `1 → 15 000`, `2 → 25 000`, `3 → 30 000`. Le plancher PDF est 7 000 € pour un geste seul ; le code part de 15 000 € directement. | ⚠️ écart (mineur, surévalue le plafond pour 1 geste) | Vérifier si la fiche officielle service-public.fr distingue le mono-geste (souvent 15 000 € pour bouquets, 7 000 € pour mono-geste isolé). |
| Durée max | « 15 ans maximum » côté par geste | `note:` du financement (l.593) dit « Durée max 20 ans » | ⚠️ écart | Le code fixe une note unique pour les deux parcours (ampleur = 20 ans, par geste = 15 ans). Distinguer dans la note selon `eligible_parcours_accompagne?`. |

---

## 3. Parcours « Rénovation d'ampleur »

### 3.1 MaPrimeRénov' Rénovation d'ampleur

| Dispositif | Valeur ALEC 2026 | Implémentation actuelle | Statut | Action |
|---|---|---|---|---|
| Taux nationaux (gain 2-3 sauts) | TM 80 % / M 60 % / I 45 % / S 10 % | `MPR_TAUX_2026` (l.54-59) : 0.80 / 0.60 / 0.45 / 0.10 | ✅ conforme (taux nationaux) |  |
| Majoration **+10 % sur taux Grand Nancy** | « Majoration de 10 % sur les taux nationaux sur la Métropole du Grand Nancy » (note PDF p.1) | **Absente.** `MPR_TAUX_2026` est appliqué tel quel quel que soit `code_insee`. | ⚠️ écart majeur | Avant vendredi : confirmer avec l'ALEC si ce + 10 % est additif (taux passent à 90/70/55/20 %) ou multiplicatif (taux × 1.1). Implémenter conditionné à `territory_grand_nancy?`. |
| Majoration **+500 € Département 54** | Cumulable avec... | **Absente.** | ❌ manquant | Voir Priorités. |
| Bonus **+1 000 € matériaux biosourcés** | … bonus 1 000 € si matériaux biosourcés | **Absente** (`Property` n'a pas non plus de drapeau « biosourcé » ; `analysis.content` JSON éventuellement). | ❌ manquant | Voir Priorités (nécessite donnée de saisie). |
| Plafonds de dépenses HT | 30 000 € (saut 2) / 40 000 € (saut 3 ou +) | `MPR_PLAFOND_TRAVAUX_HT` (l.62-66) : 2→30 000, 3→40 000, 4→40 000 | ✅ conforme | — |
| Écrêtement TTC (cumul max) | TM 100 % / M 90 % / I 80 % / S 50 % | `MPR_AMPLEUR_CUMUL_CAP` (l.70-75) : 1.00 / 0.90 / 0.80 / 0.50 | ✅ conforme | — |
| DPE actuel obligatoire E/F/G | Oui | Check ligne 376 | ✅ conforme | — |
| Saut ≥ 2 classes | Oui | `eligible_parcours_accompagne?` (l.718-723) check `saut >= 2` | ✅ conforme | — |
| ≥ 2 gestes d'isolation + ventilation | Oui | Même méthode, comptage et `ventilation` | ✅ conforme | — |
| Accompagnateur Rénov' obligatoire | Oui | Note libre dans `aid_calculator_service.rb:407` (« CEE intégré au parcours accompagné »). Pas de hard-check (le service ne demande pas si l'utilisateur a un MAR). | ❓ à clarifier | Statut affiché à l'utilisateur — pour vendredi, ajouter une mention dans la card MPR Ampleur. |
| Exclusion fioul / gaz naturel | Oui (le projet ne doit pas garder du fioul ni installer du gaz) | Pas tracé. Le code n'examine pas le `heating_type` du logement. | ❓ à clarifier | Risque modéré : si l'utilisateur reste au fioul, on affiche quand même MPR Ampleur. |

### 3.2 Éco-PTZ (parcours ampleur)

| Dispositif | Valeur ALEC 2026 | Implémentation actuelle | Statut | Action |
|---|---|---|---|---|
| Montant max | 50 000 € | `ECO_PTZ_RENO_GLOBALE = 50_000` (l.275) | ✅ conforme | — |
| Durée max | 20 ans | Note libre l.593 dit 20 ans | ✅ conforme côté ampleur (incompatible côté par geste — cf. 2.7) | — |
| Cumulable avec MPR Accompagné | Oui | Aucun blocage côté code | ✅ conforme | — |

### 3.3 Loc'Avantages

| Dispositif | Valeur ALEC 2026 | Implémentation actuelle | Statut | Action |
|---|---|---|---|---|
| Loc'Avantages (bailleurs > 15 ans, conventionné 6 ans, gain énergétique ≥ 35 % ou rénovation globale) | 25 % ou 35 % HT travaux (plafonnés 60 000 / 80 000 € HT) + avantage fiscal | **Absente.** | ❌ manquant | Voir Priorités. |

### 3.4 Aides Métropole Grand Nancy (rénovation d'ampleur)

**PDF p.2 — point central.**

| Type de projet | Plafond dépenses éligibles HT | Tous profils RFR |
|---|---|---|
| Étiquette A ou B avec gain de 2 classes | Idem MPR Parcours Accompagné | **15 % (plafonné à 4 500 € d'aide)** |
| Étiquette A ou B avec gain de 3 classes ou plus | Idem MPR Parcours Accompagné | **15 % (plafonné à 6 000 € d'aide)** |

| Dispositif | Valeur ALEC 2026 | Implémentation actuelle | Statut | Action |
|---|---|---|---|---|
| Taux & plafonds Grand Nancy ampleur | Uniforme **15 %**, plafond conditionné au saut (**4 500 €** pour 2 sauts, **6 000 €** pour 3+ sauts), exigence étiquette A ou B après travaux | `GN_RENO_GLOBALE_TAUX` (l.300-305) : taux différenciés par tranche (TM/M 25 % ou 15 %, I/S 15 % ou 5 %), plafonds différenciés par tranche (10 000 / 7 500 / 5 000 / 2 500 €), distinction « sortie passoire » qui n'est pas dans la fiche ALEC 2026. **C'est l'écart le plus visible si confronté à la fiche officielle.** | ⚠️ écart majeur | **Avant vendredi.** Vérifier laquelle des deux versions est en vigueur : la fiche ALEC papier de mai 2026 (15 % uniforme, plafond par saut) ou le règlement d'intervention Métropole 06/06/2024 cité en commentaire l.16. Si la fiche ALEC fait foi, refactorer en `{ taux: 0.15, plafond_2_sauts: 4_500, plafond_3_sauts: 6_000 }`. |
| Conditionnement « avant travaux » | Oui | Note libre l.710 (« Contact ALEC Nancy obligatoire avant travaux. ») | ✅ conforme | — |

### 3.5 ComCom Seille et Grand Couronné (parcours ampleur)

| Dispositif | Valeur ALEC 2026 | Implémentation actuelle | Statut | Action |
|---|---|---|---|---|
| Bonification MPR Ampleur ComCom Seille et Grand Couronné | 1 000 € à 2 000 € selon revenus | **Absente.** | ❌ manquant | Voir Priorités. |
| Aides supplémentaires communales | 300 à 500 € sur certaines communes du territoire | **Absente.** | ❌ manquant | Voir Priorités. |
| Bonus Région Grand Est BBC | 800 € (ménages modestes, sortie G/F/E avec audit scénario BBC) ou 2 000 € si niveau BBC atteint | **Absente.** | ❌ manquant | Voir Priorités. |

---

## 4. Parcours « Copropriété »

**Couverture actuelle : NULLE.** `AidCalculatorService` ne traite que les
biens dont `property_type = "maison"` (cf. `maison_individuelle?` l.741-743),
et seules les aides Grand Nancy testent ce flag. Pour les appartements
(`property_type = "appartement"`), aucune aide copropriété n'est calculée :
MPR Copro, Plan Climat copro, CLIMAXION, CEE collectif et éco-PTZ collectif
sont tous absents.

| Dispositif | Valeur ALEC 2026 | Implémentation actuelle | Statut | Action |
|---|---|---|---|---|
| **MaPrimeRénov' Copropriété** — gain 35 % | 30 % HT plafonné 25 000 € HT/log (= 7 500 €/log max) | Absente | ❌ manquant | Chantier de fond. |
| **MaPrimeRénov' Copropriété** — gain 50 % | 45 % HT plafonné 25 000 € HT/log (= 11 250 €/log max) | Absente | ❌ manquant | Chantier de fond. |
| MPR Copro — Bonus sortie passoire | + 10 % | Absente | ❌ manquant | Chantier de fond. |
| MPR Copro — Bonus copropriété fragile | + 20 % (non cumulable CEE) | Absente | ❌ manquant | Chantier de fond. |
| MPR Copro — Bonus individuel propriétaire occupant | 3 000 € TM / 1 500 € M | Absente | ❌ manquant | Chantier de fond. |
| **Plan Climat Grand Nancy Copro — Audit énergétique** | 50 % TTC plafonné 5 000 € par copro | Absente | ❌ manquant | Chantier de fond. |
| **Plan Climat Grand Nancy Copro — Bonus BBC** | Copro saine : 10 % HT plafonné 2 500 €/log · Copro fragile : 15 % HT plafonné 3 250 €/log | Absente | ❌ manquant | Chantier de fond. |
| Plan Climat — Bonus individuel proprio occupant | 1 500 € si TM ou M | Absente | ❌ manquant | Chantier de fond. |
| **Plan Climat — Isolation immeubles avant 1948** (hors MPR Copro) | Murs façade arrière/pignon 30/40 €/m², Sarking 25/50, Combles perdus 5/10, Toitures terrasses 30/40, Plancher bas 10/15 (saines / fragiles) | Absente | ❌ manquant | Chantier de fond. |
| **CLIMAXION (ADEME-Région Grand Est)** | Bouquet 3 travaux (Murs + plancher bas + toiture) : 10 000 €/12 500 €/15 000 € selon taille copro + 2 500 €/log, plafond 200 000 € · Bouquet 2 travaux Murs+toiture : 1 500 €/log, plafond 120 000 € · Bouquet 2 travaux Murs+plancher bas : 1 200 €/log, plafond 96 000 € + bonus biosourcés (fenêtres collectives 1 000 €, ITE biosourcée 2 000 €, ITI biosourcée 1 000 €, toiture biosourcée 200 € — par logement) | Absente | ❌ manquant | Chantier de fond. |
| **CEE collectif copropriété** | Estimations : 8-10 €/m² murs, 6-10 €/m² toiture, 6-8 €/m² plancher bas, 80-150 €/log VMC | Absente | ❌ manquant | Chantier de fond. |
| **Éco-PTZ collectif** | Action seule 15 000 € · Bouquet 2 trav. 25 000 € · Bouquet 3 trav. 30 000 € · Performance globale (≥ 35 %) 50 000 € — par logement | Absente | ❌ manquant | Chantier de fond. |

---

## 5. Données structurelles / dette technique

| Sujet | Constat | Statut | Action |
|---|---|---|---|
| Mapping RFR → bracket | Inexistant (cf. § 1) | ❌ manquant | Avant vendredi : sous-labels honnêtes ; chantier : table RFR×ménage. |
| Colonne `household_size` sur Property | N'existe pas | ❌ manquant | Chantier de fond. |
| `LocalAidScheme` jamais seedé | Aucun `db/seeds*.rb` ne crée de `LocalAidScheme` ; admin controller existant (`app/controllers/admin/local_aid_schemes_controller.rb`) | ❓ à clarifier en prod | Chantier de fond : ou bien on en fait la source unique des aides locales, ou bien on retire la table. |
| Duplication Grand Nancy (en dur + AidRule + LocalAidScheme) | 3 sources de vérité possibles | ⚠️ dette | Chantier de fond : choisir une seule source ; la donnée éditable a la préférence pour que l'ALEC maintienne sans redéploiement. |
| Dette `AidRule` | Colonnes `conditions/amount_type/amount_value/amount_max/amount_min/amount_base/amount_notes` non lues par `AidCalculatorService` | ⚠️ dette | Chantier de fond. |
| Couverture appartements | Tout `maison_individuelle? == false` → aucune aide calculée | ❌ manquant (cf. § 4) | Chantier de fond. |
| Filtrage SCI | Pas tracé | ❓ | Documentation suffisante pour vendredi. |
| Exclusion chauffage fioul/gaz naturel en MPR Ampleur | Pas tracée | ❓ | À ajouter à terme. |

---

## 6. Priorités

### 6.1 À corriger / valider AVANT vendredi

Choix : ne traiter que les écarts qui décrédibiliseraient devant un
conseiller ALEC qui ouvre l'app à côté de sa fiche.

1. **Sous-labels RFR honnêtes** (`_aid_result.html.erb:19-23`).
   Les seuils figés « < 21 000 €/an » etc. ne correspondent à aucune ligne
   de la grille ALEC. Solution rapide : retirer les sous-labels ou les
   remplacer par « selon votre nombre de personnes au foyer ».
2. **Grand Nancy rénovation globale** (§ 3.4).
   `GN_RENO_GLOBALE_TAUX` (taux 25 %/15 % puis 15 %/5 %, plafonds 10/7.5/5/2.5 k€)
   est en contradiction frontale avec la fiche ALEC 2026 (**15 % uniforme,
   plafond 4 500 € / 6 000 € selon saut de classes**). Confirmer la version
   en vigueur auprès de l'ALEC : si la fiche papier fait foi, l'écart se
   verra immédiatement sur un cas concret. Tant que ce n'est pas tranché,
   ajouter un disclaimer dans la card.
3. **Majoration + 10 % Grand Nancy sur taux MPR Ampleur** (§ 3.1).
   Préciser avec l'ALEC : additif (TM = 90 %, M = 70 %, I = 55 %, S = 20 %)
   ou multiplicatif. C'est un point de mesure et un argument commercial.
   À ajouter au moins en mention textuelle dans la card MPR Ampleur Grand
   Nancy.
4. **Bonus Dept 54 (+500 €)** (§ 3.1).
   Aide forfaitaire simple, indépendante des matériaux. Ajout possible en
   une constante. Visible immédiatement par un utilisateur du 54.
5. **Note Éco-PTZ par-geste = 15 ans** (§ 2.7).
   Distinguer la note « 20 ans » (ampleur) de « 15 ans » (par geste).

### 6.2 Chantier de fond

Pour que l'ALEC puisse maintenir le catalogue sans redéploiement.

1. **Externaliser le catalogue d'aides** vers `LocalAidScheme` (ou un
   refactor de `AidRule` qui devient la table cible).
   - Choisir une seule source de vérité — soit `AidRule`, soit
     `LocalAidScheme` — et supprimer l'autre.
   - Le service de calcul lit la donnée et applique des règles génériques
     (% HT, forfait fixe, €/m², plafond, écrêtement, conditions
     d'éligibilité encodées en jsonb).
   - Ajouter une interface d'admin (le controller existe déjà pour
     `LocalAidScheme`) pour que l'ALEC édite les chiffres.
2. **`household_size` + `IncomeBracketResolver`.**
   - Colonne `household_size:integer` sur `Property`.
   - Service qui, à partir de `rfr` (saisi par l'utilisateur) et de
     `household_size`, retourne le bracket en consultant la grille ALEC
     versionnée par année.
   - Garder le sélecteur direct comme fallback / shortcut.
3. **Bonus matériaux biosourcés.**
   - Drapeau côté Property (ou champ tiré de `analysis.content`).
   - Branche +1 000 € MPR Ampleur, +2 000 € CLIMAXION ITE biosourcée, etc.
4. **Couvrir le parcours copropriété** (§ 4).
   - Implique probablement un autre périmètre d'objet métier
     (Coproperty / Building) — ce n'est pas qu'un calcul de plus, c'est un
     parcours utilisateur entier. À cadrer avec l'ALEC : volume réel
     d'appartements dans l'audience cible.
5. **ComCom (Sel et Vermois, Seille et Grand Couronné), Région Grand Est,
   Prime Air Bois, Loc'Avantages** (§ 2.4-2.6, 3.3, 3.5).
   - Une fois le catalogue éditable, ces aides deviennent du paramétrage.
     Tant que tout est en dur dans le service, chaque ajout coûte un
     développement complet.
6. **Garde-fous d'éligibilité aujourd'hui non tracés.**
   - Exclusion chauffage fioul/gaz naturel (MPR Ampleur).
   - SCI (MPR Par geste).
   - Conditionnement obligatoire CEE → Métropole Grand Nancy (Plan Climat).

---

## 7. Résumé — verdict global

| Parcours | Couverture vs ALEC 2026 |
|---|---|
| **Par geste** | MPR + CEE + Éco-PTZ + Grand Nancy isolation : **conformes** sur les barèmes (Grand Nancy isolation est exact au € près). Manquent : Prime Air Bois, ComCom Sel et Vermois, ComCom Seille et Grand Couronné, durée éco-PTZ. |
| **Rénovation d'ampleur** | Cadre national MPR (taux nationaux, plafonds HT, cap TTC) : **conforme**. Grand Nancy : **écart majeur sur les taux et plafonds** + majoration 10 % non implémentée. Bonus Dept 54 / biosourcés / Loc'Avantages / ComCom Seille / Région Grand Est BBC : **tous absents**. |
| **Copropriété** | **Couverture nulle.** Aucune des aides MPR Copro, Plan Climat Copro, CLIMAXION, CEE collectif, éco-PTZ collectif n'est calculée. |

**Risque principal devant l'ALEC.** Un utilisateur de la Métropole Grand
Nancy avec un projet de rénovation globale verra aujourd'hui un montant
Grand Nancy qui peut atteindre 10 000 € (cas TM, taux 25 %), alors que la
fiche ALEC 2026 plafonne à 4 500 € ou 6 000 €. C'est le seul écart de
chiffres susceptible d'être perçu comme une erreur grossière en
démonstration. Tout le reste est soit conforme, soit un manque (qui se
défend en disant « pas encore couvert »).
