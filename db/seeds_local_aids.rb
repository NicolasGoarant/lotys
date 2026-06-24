# db/seeds_local_aids.rb
# ============================================================
# Règles d'aides — Grand Nancy + National
# Sources :
#   - ANAH / MaPrimeRénov' : règles 2026 (réouverture 23/02/2026)
#   - CEE : arrêtés Coup de pouce 2026 (BAR-EN-101/102/103, BAR-TH-*)
#   - Éco-PTZ : effy.fr / service-public.fr 2026
#   - Grand Nancy : Règlement d'intervention maisons individuelles
#     (délibération 06/06/2024, en vigueur 01/10/2024 → 31/12/2029)
# Dernière mise à jour : juin 2026
#
# IMPORTANT — ce que le service consomme réellement :
#   AidCalculatorService ne lit de la rule QUE { slug, name, source_label,
#   valid_until }. Tous les taux/forfaits/plafonds de calcul sont des
#   CONSTANTES du service (MPR_TAUX_2026, MPR_PAR_GESTE_FORFAITS,
#   CEE_FORFAITS, etc.) — ce fichier est donc DOCUMENTAIRE pour les
#   champs amount_max, amount_notes, conditions. Les chiffres ci-dessous
#   doivent refléter ces constantes, pas en inventer de nouveaux.
#
# Idempotence : on utilise find_or_create_by(slug:) — rejouer ce script
# en prod ne touche pas aux règles déjà présentes (pas de fenêtre où la
# table est vide). Pour MODIFIER une règle existante : il faut soit
# détruire la ligne et relancer, soit modifier en console — ce script
# n'écrase pas les attributs existants.
# ============================================================

# ============================================================
# 1. MaPrimeRénov' — Parcours accompagné (rénovation d'ampleur)
# ============================================================
AidRule.find_or_create_by(slug: "mpr_parcours_accompagne") do |r|
  r.name         = "MaPrimeRénov' — Parcours accompagné"
  r.aid_type     = "mpr"
  r.territory    = "national"
  r.description  = "Aide ANAH pour rénovation d'ampleur. " \
                   "DPE actuel E/F/G obligatoire. ≥ 2 gestes isolation + ventilation + saut ≥ 2 classes DPE. " \
                   "Accompagnateur Rénov' obligatoire. Rendez-vous France Rénov' obligatoire avant dépôt."
  r.conditions   = {
    dpe_actuel:          { operator: "in",  value: ["E", "F", "G"] },
    nb_gestes_isolation: { operator: ">=",  value: 2 },
    ventilation_traitee: { operator: "==",  value: true },
    dpe_saut_classes:    { operator: ">=",  value: 2 },
    anciennete_ans:      { operator: ">=",  value: 15 },
    income_bracket:      { operator: "in",  value: ["tres_modeste", "modeste", "intermediaire", "superieur"] }
  }
  r.amount_type  = "percentage"
  r.amount_base  = "cost_ht"
  r.amount_notes = "Taux 2026 : Très modestes 80% | Modestes 60% | Intermédiaires 45% | Supérieurs 10%. " \
                   "Plafond travaux HT : 30 000 € (saut 2-3 classes) ou 40 000 € (saut 3+ classes). " \
                   "Bonus sortie passoire SUPPRIMÉ depuis sept. 2025."
  # Source : MPR_TAUX_2026 × max(MPR_PLAFOND_TRAVAUX_HT) = 0.80 × 40 000
  r.amount_max   = 32_000.0
  r.amount_min   = nil
  r.valid_from   = Date.new(2024, 1, 1)
  r.valid_until  = nil
  r.active       = true
  r.source_url   = "https://www.economie.gouv.fr/particuliers/faire-des-economies-denergie/maprimerenov-renovation-dampleur-tout-savoir-sur-cette-aide"
  r.source_label = "ANAH — MaPrimeRénov' Rénovation d'ampleur 2026"
  r.priority     = 10
end

# ============================================================
# 2. MaPrimeRénov' — Par geste (rénovation par travail isolé)
# ============================================================
# Forfaits unitaires (€/équipement) ou surfaciques (€/m²) selon le geste.
# Toléré absent par AidCalculatorService (fallback rule&.slug l. 538),
# mais on le seede pour cohérence avec les 4 autres règles et pour que
# source_label remonte la version exacte à la fiche.
# ============================================================
AidRule.find_or_create_by(slug: "mpr_par_geste") do |r|
  r.name         = "MaPrimeRénov' — Par geste"
  r.aid_type     = "mpr"
  r.territory    = "national"
  r.description  = "Aide ANAH par travail isolé (chauffage, ECS, isolation par poste, VMC, audit). " \
                   "Forfaits fixes par geste, modulés par profil de revenus. " \
                   "Supérieurs NON éligibles à MPR Par geste (CEE seul). " \
                   "Logement achevé depuis ≥ 15 ans, résidence principale. " \
                   "Devis RGE obligatoire. Dépôt sur maprimerenov.gouv.fr AVANT signature."
  r.conditions   = {
    anciennete_ans: { operator: ">=", value: 15 },
    income_bracket: { operator: "in", value: ["tres_modeste", "modeste", "intermediaire"] }
  }
  # Forfaits unitaires (€/équipement) ET surfaciques (€/m²) selon le geste.
  r.amount_type  = "mixed"
  r.amount_base  = nil
  r.amount_notes = "Forfaits unitaires (TM | MO | INT) — extraits de MPR_PAR_GESTE_FORFAITS : " \
                   "PAC air/eau 5000 | 4000 | 3000 € · " \
                   "PAC géothermique 11 000 | 9000 | 6000 € · " \
                   "Système solaire combiné 10 000 | 8000 | 4000 € · " \
                   "VMC double flux 2500 | 2000 | 1500 € · " \
                   "Audit énergétique 500 | 400 | 300 €. " \
                   "Forfaits surfaciques : rampants 25 | 20 | 15 €/m² · " \
                   "toiture-terrasse 75 | 60 | 40 €/m² · fenêtres 100 | 80 | 40 €/équipement. " \
                   "Cumul MPR + CEE plafonné en % TTC (MPR_PAR_GESTE_CUMUL_CAP) : " \
                   "TM 90% | MO 75% | INT 60%. Supérieurs : pas de MPR, CEE seul."
  # Pas de cap simple en €. Le cumul effectif dépend du mix de gestes ET
  # du budget TTC via MPR_PAR_GESTE_CUMUL_CAP. → nil honnête.
  r.amount_max   = nil
  r.amount_min   = nil
  r.valid_from   = Date.new(2024, 1, 1)
  r.valid_until  = nil
  r.active       = true
  r.source_url   = "https://www.economie.gouv.fr/particuliers/maprimerenov-tout-savoir-sur-cette-aide-renovation-energetique"
  r.source_label = "ANAH — MaPrimeRénov' Par geste 2026"
  r.priority     = 20
end

# ============================================================
# 3. Certificats d'Économies d'Énergie (CEE)
# ============================================================
# Dispositif national, montants VARIABLES selon le signataire/agrégateur.
# Toléré absent par AidCalculatorService (fallback rule&.slug l. 459, 553),
# seedé ici pour cohérence + traçabilité de la source.
# ============================================================
AidRule.find_or_create_by(slug: "cee") do |r|
  r.name         = "Certificats d'Économies d'Énergie"
  r.aid_type     = "cee"
  r.territory    = "national"
  r.description  = "Prime versée par les fournisseurs d'énergie sur opérations standardisées " \
                   "(BAR-EN-101 ITI, BAR-EN-102 ITE, BAR-TH-* chauffage/ECS, etc.). " \
                   "Coup de pouce isolation et chauffage majoré pour ménages modestes et très modestes. " \
                   "Cumulable avec MaPrimeRénov'. Devis et signature des CEE AVANT démarrage des travaux."
  r.conditions   = {
    anciennete_ans: { operator: ">=", value: 2 }
  }
  # Forfaits unitaires (€/équipement) ET surfaciques (€/m²), variables
  # selon le profil et le signataire.
  r.amount_type  = "mixed"
  r.amount_base  = nil
  r.amount_notes = "Forfaits INDICATIFS (TM | MO | INT/SUP) — extraits de CEE_FORFAITS du service : " \
                   "ITE 15 | 12 | 12 €/m² · ITI 9 | 7 | 7 €/m² · rampants 12 | 11 | 11 €/m² · " \
                   "PAC air/eau 4000 | 4000 | 2500 € · PAC géo 5000 € (tous profils) · " \
                   "VMC double flux 300 | 260 | 260 €. " \
                   "Montants RÉELS variables selon le signataire CEE (fournisseur d'énergie ou agrégateur) — " \
                   "il est impératif de COMPARER plusieurs offres avant signature."
  r.amount_max   = nil   # variable par nature — pas de plafond commun
  r.amount_min   = nil
  r.valid_from   = Date.new(2024, 1, 1)
  r.valid_until  = nil
  r.active       = true
  r.source_url   = "https://www.ecologie.gouv.fr/dispositif-des-certificats-deconomies-denergie"
  r.source_label = "Ministère de la Transition écologique — CEE (forfaits 2026)"
  r.priority     = 25
end

# ============================================================
# 4. Éco-PTZ — Prêt à taux zéro travaux (FINANCEMENT)
# ============================================================
AidRule.find_or_create_by(slug: "eco_ptz") do |r|
  r.name         = "Éco-PTZ — Prêt à taux zéro travaux"
  r.aid_type     = "eco_ptz"
  r.territory    = "national"
  r.description  = "Prêt à taux zéro, sans condition de revenus. " \
                   "PRÊT REMBOURSABLE — ne réduit pas le coût des travaux, finance le reste à charge. " \
                   "Durée max 20 ans. Logement achevé depuis ≥ 2 ans, résidence principale."
  r.conditions   = {
    nb_gestes:   { operator: ">=", value: 1 },
    anciennete:  { operator: ">=", value: 2 }
  }
  r.amount_type  = "fixed"
  r.amount_notes = "Grille 2026 : 1 poste → 15 000 € | 2 postes → 25 000 € | 3 postes → 30 000 € | " \
                   "Rénovation globale (gain ≥ 35% + sortie passoire) → 50 000 €. " \
                   "Cumulable avec MaPrimeRénov'. Durée max 20 ans."
  r.amount_value = 30_000.0
  r.amount_max   = 50_000.0
  r.amount_min   = 15_000.0
  r.valid_from   = Date.new(2024, 1, 1)
  r.valid_until  = nil
  r.active       = true
  r.source_url   = "https://www.service-public.fr/particuliers/vosdroits/F19905"
  r.source_label = "Service Public — Éco-PTZ 2026"
  r.priority     = 30
end

# ============================================================
# 5. Grand Nancy — Aide aux travaux d'ISOLATION (€/m²)
# ============================================================
# Pour projets HORS MPR parcours accompagné.
# Cible : étiquette C minimum. Maisons individuelles uniquement.
# Cumulable avec CEE Primes énergie Grand Nancy uniquement.
# ============================================================
AidRule.find_or_create_by(slug: "grand_nancy_isolation") do |r|
  r.name         = "Grand Nancy — Aide travaux d'isolation"
  r.aid_type     = "local"
  r.territory    = "grand_nancy"
  r.description  = "Aide aux derniers gestes d'isolation pour projets ne rentrant PAS dans MPR parcours accompagné. " \
                   "Maisons individuelles uniquement. Résidence principale. Achevé depuis ≥ 15 ans. " \
                   "Cible : étiquette C minimum (≤ 150 kWhEP/m².an). " \
                   "Contact ALEC Nancy obligatoire avant travaux."
  r.conditions   = {
    territory:         { operator: "==",  value: "grand_nancy" },
    property_type:     { operator: "==",  value: "maison" },
    dpe_cible:         { operator: "in",  value: ["A", "B", "C"] },
    parcours_accompagne: { operator: "==", value: false },
    anciennete_ans:    { operator: ">=",  value: 15 }
  }
  r.amount_type  = "per_m2"
  r.amount_notes = "Ménages modestes/très modestes : ITE 40€/m² | ITI 10€/m² | Sarking 50€/m² | " \
                   "Combles perdus 10€/m² | Toitures terrasses 40€/m² | Planchers bas 15€/m². " \
                   "Ménages intermédiaires/supérieurs : ITE 30€/m² | ITI 5€/m² | Sarking 40€/m² | " \
                   "Combles perdus 5€/m² | Toitures terrasses 30€/m² | Planchers bas 10€/m². " \
                   "Source : Règlement d'intervention Grand Nancy, art. 3 (délibération 06/06/2024)."
  r.amount_value = nil
  r.amount_max   = nil
  r.valid_from   = Date.new(2024, 10, 1)
  r.valid_until  = Date.new(2029, 12, 31)
  r.active       = true
  r.source_url   = "https://www.grandnancy.eu/vivre-habiter/primes-energie/particuliers"
  r.source_label = "Métropole du Grand Nancy — Aide isolation (oct. 2024 → déc. 2029)"
  r.priority     = 40
end

# ============================================================
# 6. Grand Nancy — Aide à la RÉNOVATION GLOBALE (% MPR)
# ============================================================
# Pour projets s'inscrivant dans MPR parcours accompagné.
# Cible : étiquette A ou B (≤ 110 kWhEP/m².an).
# Subordonné à la perception effective de MaPrimeRénov'.
# NON cumulable avec l'aide isolation Grand Nancy.
# ============================================================
AidRule.find_or_create_by(slug: "grand_nancy_renovation_globale") do |r|
  r.name         = "Grand Nancy — Aide rénovation globale (abondement MPR)"
  r.aid_type     = "local"
  r.territory    = "grand_nancy"
  r.description  = "Bonification de la Métropole du Grand Nancy pour projets de rénovation d'ampleur " \
                   "visant l'étiquette A ou B (≤ 110 kWhEP/m².an). " \
                   "Subordonné à la perception de MaPrimeRénov' parcours accompagné. " \
                   "Maisons individuelles uniquement. Contact ALEC Nancy obligatoire avant travaux."
  r.conditions   = {
    territory:           { operator: "==", value: "grand_nancy" },
    property_type:       { operator: "==", value: "maison" },
    dpe_cible:           { operator: "in", value: ["A", "B"] },
    parcours_accompagne: { operator: "==", value: true },
    anciennete_ans:      { operator: ">=", value: 15 }
  }
  r.amount_type  = "percentage"
  r.amount_base  = "cost_ht"
  r.amount_notes = "Taux appliqué sur les dépenses éligibles MPR (HT) : " \
                   "Très modestes : 25% (cible A/B) ou 15% (sortie passoire) — plafond 10 000 € | " \
                   "Modestes : 25% ou 15% — plafond 7 500 € | " \
                   "Intermédiaires : 15% ou 5% — plafond 5 000 € | " \
                   "Supérieurs : 15% ou 5% — plafond 2 500 €. " \
                   "Source : Règlement d'intervention Grand Nancy, art. 3 (délibération 06/06/2024)."
  r.amount_value = nil
  r.amount_max   = 10_000.0
  r.amount_min   = nil
  r.valid_from   = Date.new(2024, 10, 1)
  r.valid_until  = Date.new(2029, 12, 31)
  r.active       = true
  r.source_url   = "https://www.grandnancy.eu/vivre-habiter/primes-energie/particuliers"
  r.source_label = "Métropole du Grand Nancy — Rénovation globale (oct. 2024 → déc. 2029)"
  r.priority     = 50
end

puts "✅ #{AidRule.count} règles d'aides en base"
puts ""
AidRule.order(:priority).each do |r|
  status = r.valid_until ? "→ #{r.valid_until}" : "sans limite"
  puts "  #{r.priority.to_s.rjust(2)}. [#{r.territory.upcase}] #{r.name} (#{status})"
end
