puts "🏛️  Dispositifs d'aides locales..."
LocalAidResult.destroy_all
LocalAidScheme.destroy_all

GN = %w[54000 54100 54110 54112 54140 54179 54180
        54185 54220 54230 54280 54320 54360 54390
        54400 54500 54510 54520 54560 54600].freeze

LocalAidScheme.create!(
  name: "Métropole Grand Nancy — Rénovation globale",
  territory: "Grand Nancy", aid_type: "renov_globale",
  zipcodes: GN, property_types: nil,
  rate_tres_modeste: 25, rate_modeste: 25, rate_intermediaire: 15, rate_superieur: 15,
  max_tres_modeste: 10_000, max_modeste: 7_500, max_intermediaire: 5_000, max_superieur: 2_500,
  conditions_text: "Aide complémentaire à MaPrimeRénov' parcours accompagné. Objectif DPE A ou B (< 110 kWhEP/m².an). MonAccompagnateurRénov' agréé obligatoire. Conditionnée à l'obtention de MaPrimeRénov'.",
  warning_text: "⚠️ Condition bloquante : contacter l'ALEC Nancy Grands Territoires AVANT tout démarrage de travaux ou signature de devis. Sans cette prise de contact, le dossier est irrecevable.",
  contact_name: "ALEC Nancy Grands Territoires — espace conseil France Rénov'",
  contact_url: "https://alec-nancy.fr",
  source_url: "https://www.grandnancy.eu/fileadmin/user_upload/REGLEMENT_aides_maisons_individuelles.pdf",
  source_label: "Règlement Métropole Grand Nancy — en vigueur depuis le 01/10/2024",
  valid_from: Date.new(2024, 10, 1), valid_until: Date.new(2029, 12, 31), active: true
)

LocalAidScheme.create!(
  name: "Métropole Grand Nancy — Travaux d'isolation",
  territory: "Grand Nancy", aid_type: "isolation",
  zipcodes: GN, property_types: nil,
  forfait_data: {
    "murs_ext"         => { "tres_modeste_et_modeste" => 40, "intermediaire_et_superieur" => 30 },
    "murs_int"         => { "tres_modeste_et_modeste" => 10, "intermediaire_et_superieur" => 5  },
    "sarking"          => { "tres_modeste_et_modeste" => 50, "intermediaire_et_superieur" => 40 },
    "combles_perdus"   => { "tres_modeste_et_modeste" => 10, "intermediaire_et_superieur" => 5  },
    "toiture_terrasse" => { "tres_modeste_et_modeste" => 40, "intermediaire_et_superieur" => 30 },
    "planchers_bas"    => { "tres_modeste_et_modeste" => 15, "intermediaire_et_superieur" => 10 }
  },
  conditions_text: "Réservé aux projets ne pouvant bénéficier de MaPrimeRénov' accompagné (impossibilité à justifier). Objectif DPE C minimum. Entreprise RGE obligatoire. Cumul CEE possible.",
  warning_text: "⚠️ Condition bloquante : contacter l'ALEC Nancy Grands Territoires AVANT tout démarrage. Justificatif d'impossibilité de rénovation globale requis.",
  contact_name: "ALEC Nancy Grands Territoires — espace conseil France Rénov'",
  contact_url: "https://alec-nancy.fr",
  source_url: "https://www.grandnancy.eu/fileadmin/user_upload/REGLEMENT_aides_maisons_individuelles.pdf",
  source_label: "Règlement Métropole Grand Nancy — en vigueur depuis le 01/10/2024",
  valid_from: Date.new(2024, 10, 1), valid_until: Date.new(2029, 12, 31), active: true
)

puts "  → #{LocalAidScheme.count} dispositifs créés"
