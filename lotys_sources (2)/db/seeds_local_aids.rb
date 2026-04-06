# db/seeds_local_aids.rb
# ============================================================
# Règles d'aides — Grand Nancy + National
# Sources :
#   - ANAH / MaPrimeRénov' : règles 2026 (réouverture 23/02/2026)
#   - Éco-PTZ : effy.fr / service-public.fr 2026
#   - Grand Nancy : Règlement d'intervention maisons individuelles
#     (délibération 06/06/2024, en vigueur 01/10/2024 → 31/12/2029)
# Dernière mise à jour : mars 2026
# ============================================================

AidRule.delete_all

# ============================================================
# 1. MaPrimeRénov' — Parcours accompagné (rénovation d'ampleur)
# ============================================================
AidRule.create!(
  name:         "MaPrimeRénov' — Parcours accompagné",
  slug:         "mpr_parcours_accompagne",
  aid_type:     "mpr",
  territory:    "national",
  description:  "Aide ANAH pour rénovation d'ampleur. " \
                "DPE actuel E/F/G obligatoire. ≥ 2 gestes isolation + ventilation + saut ≥ 2 classes DPE. " \
                "Accompagnateur Rénov' obligatoire. Rendez-vous France Rénov' obligatoire avant dépôt.",
  conditions: {
    dpe_actuel:          { operator: "in",  value: ["E", "F", "G"] },
    nb_gestes_isolation: { operator: ">=",  value: 2 },
    ventilation_traitee: { operator: "==",  value: true },
    dpe_saut_classes:    { operator: ">=",  value: 2 },
    anciennete_ans:      { operator: ">=",  value: 15 },
    income_bracket:      { operator: "in",  value: ["tres_modeste", "modeste", "intermediaire", "superieur"] }
  },
  amount_type:  "percentage",
  amount_base:  "cost_ht",
  amount_notes: "Taux 2026 : Très modestes 80% | Modestes 60% | Intermédiaires 45% | Supérieurs 10%. " \
                "Plafond travaux HT : 30 000 € (saut 2-3 classes) ou 40 000 € (saut 3+ classes). " \
                "Bonus sortie passoire SUPPRIMÉ depuis sept. 2025.",
  amount_max:   32_000.0,  # 80% × 40 000 HT
  amount_min:   nil,
  valid_from:   Date.new(2024, 1, 1),
  valid_until:  nil,
  active:       true,
  source_url:   "https://www.economie.gouv.fr/particuliers/faire-des-economies-denergie/maprimerenov-renovation-dampleur-tout-savoir-sur-cette-aide",
  source_label: "ANAH — MaPrimeRénov' Rénovation d'ampleur 2026",
  priority:     10
)

# ============================================================
# 2. Éco-PTZ — Prêt à taux zéro travaux (FINANCEMENT)
# ============================================================
AidRule.create!(
  name:         "Éco-PTZ — Prêt à taux zéro travaux",
  slug:         "eco_ptz",
  aid_type:     "eco_ptz",
  territory:    "national",
  description:  "Prêt à taux zéro, sans condition de revenus. " \
                "PRÊT REMBOURSABLE — ne réduit pas le coût des travaux, finance le reste à charge. " \
                "Durée max 20 ans. Logement achevé depuis ≥ 2 ans, résidence principale.",
  conditions: {
    nb_gestes:   { operator: ">=", value: 1 },
    anciennete:  { operator: ">=", value: 2 }
  },
  amount_type:  "fixed",
  amount_notes: "Grille 2026 : 1 poste → 15 000 € | 2 postes → 25 000 € | 3 postes → 30 000 € | " \
                "Rénovation globale (gain ≥ 35% + sortie passoire) → 50 000 €. " \
                "Cumulable avec MaPrimeRénov'. Durée max 20 ans.",
  amount_value: 30_000.0,
  amount_max:   50_000.0,
  amount_min:   15_000.0,
  valid_from:   Date.new(2024, 1, 1),
  valid_until:  nil,
  active:       true,
  source_url:   "https://www.service-public.fr/particuliers/vosdroits/F19905",
  source_label: "Service Public — Éco-PTZ 2026",
  priority:     30
)

# ============================================================
# 3. Grand Nancy — Aide aux travaux d'ISOLATION (€/m²)
# ============================================================
# Pour projets HORS MPR parcours accompagné.
# Cible : étiquette C minimum. Maisons individuelles uniquement.
# Cumulable avec CEE Primes énergie Grand Nancy uniquement.
# ============================================================
AidRule.create!(
  name:         "Grand Nancy — Aide travaux d'isolation",
  slug:         "grand_nancy_isolation",
  aid_type:     "local",
  territory:    "grand_nancy",
  description:  "Aide aux derniers gestes d'isolation pour projets ne rentrant PAS dans MPR parcours accompagné. " \
                "Maisons individuelles uniquement. Résidence principale. Achevé depuis ≥ 15 ans. " \
                "Cible : étiquette C minimum (≤ 150 kWhEP/m².an). " \
                "Contact ALEC Nancy obligatoire avant travaux.",
  conditions: {
    territory:         { operator: "==",  value: "grand_nancy" },
    property_type:     { operator: "==",  value: "maison" },
    dpe_cible:         { operator: "in",  value: ["A", "B", "C"] },
    parcours_accompagne: { operator: "==", value: false },
    anciennete_ans:    { operator: ">=",  value: 15 }
  },
  amount_type:  "per_m2",
  amount_notes: "Ménages modestes/très modestes : ITE 40€/m² | ITI 10€/m² | Sarking 50€/m² | " \
                "Combles perdus 10€/m² | Toitures terrasses 40€/m² | Planchers bas 15€/m². " \
                "Ménages intermédiaires/supérieurs : ITE 30€/m² | ITI 5€/m² | Sarking 40€/m² | " \
                "Combles perdus 5€/m² | Toitures terrasses 30€/m² | Planchers bas 10€/m². " \
                "Source : Règlement d'intervention Grand Nancy, art. 3 (délibération 06/06/2024).",
  amount_value: nil,
  amount_max:   nil,
  valid_from:   Date.new(2024, 10, 1),
  valid_until:  Date.new(2029, 12, 31),
  active:       true,
  source_url:   "https://www.grandnancy.eu/vivre-habiter/primes-energie/particuliers",
  source_label: "Métropole du Grand Nancy — Aide isolation (oct. 2024 → déc. 2029)",
  priority:     40
)

# ============================================================
# 4. Grand Nancy — Aide à la RÉNOVATION GLOBALE (% MPR)
# ============================================================
# Pour projets s'inscrivant dans MPR parcours accompagné.
# Cible : étiquette A ou B (≤ 110 kWhEP/m².an).
# Subordonné à la perception effective de MaPrimeRénov'.
# NON cumulable avec l'aide isolation Grand Nancy.
# ============================================================
AidRule.create!(
  name:         "Grand Nancy — Aide rénovation globale (abondement MPR)",
  slug:         "grand_nancy_renovation_globale",
  aid_type:     "local",
  territory:    "grand_nancy",
  description:  "Bonification de la Métropole du Grand Nancy pour projets de rénovation d'ampleur " \
                "visant l'étiquette A ou B (≤ 110 kWhEP/m².an). " \
                "Subordonné à la perception de MaPrimeRénov' parcours accompagné. " \
                "Maisons individuelles uniquement. Contact ALEC Nancy obligatoire avant travaux.",
  conditions: {
    territory:           { operator: "==", value: "grand_nancy" },
    property_type:       { operator: "==", value: "maison" },
    dpe_cible:           { operator: "in", value: ["A", "B"] },
    parcours_accompagne: { operator: "==", value: true },
    anciennete_ans:      { operator: ">=", value: 15 }
  },
  amount_type:  "percentage",
  amount_base:  "cost_ht",
  amount_notes: "Taux appliqué sur les dépenses éligibles MPR (HT) : " \
                "Très modestes : 25% (cible A/B) ou 15% (sortie passoire) — plafond 10 000 € | " \
                "Modestes : 25% ou 15% — plafond 7 500 € | " \
                "Intermédiaires : 15% ou 5% — plafond 5 000 € | " \
                "Supérieurs : 15% ou 5% — plafond 2 500 €. " \
                "Source : Règlement d'intervention Grand Nancy, art. 3 (délibération 06/06/2024).",
  amount_value: nil,
  amount_max:   10_000.0,
  amount_min:   nil,
  valid_from:   Date.new(2024, 10, 1),
  valid_until:  Date.new(2029, 12, 31),
  active:       true,
  source_url:   "https://www.grandnancy.eu/vivre-habiter/primes-energie/particuliers",
  source_label: "Métropole du Grand Nancy — Rénovation globale (oct. 2024 → déc. 2029)",
  priority:     50
)

puts "✅ #{AidRule.count} règles d'aides créées"
puts ""
AidRule.order(:priority).each do |r|
  status = r.valid_until ? "→ #{r.valid_until}" : "sans limite"
  puts "  #{r.priority.to_s.rjust(2)}. [#{r.territory.upcase}] #{r.name} (#{status})"
end
