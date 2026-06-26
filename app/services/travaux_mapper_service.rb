# app/services/travaux_mapper_service.rb
#
# Mappe un libellé de travail issu de l'analyse Claude vers :
#   - un code canonique (une des 7 clés de travaux_selection)
#   - un libellé affichable court
#   - un impact DPE indicatif (nombre de classes gagnées)
#
# Expose aussi un mapping macro-poste ↔ équipements détaillés / surfaces,
# utilisé par AidCalculatorService pour filtrer les aides selon les
# cases cochées par l'utilisateur dans travaux_selection.
#
# Exemples :
#   TravauxMapperService.code_for_poste("Remplacement du chauffage électrique par PAC air/eau")
#     # => "chauffage"
#   TravauxMapperService.equipements_for(["chauffage"])
#     # => ["pac_air_eau", "pac_geothermique", "poele_buches", ...]
#
# Le calcul du gain DPE par geste n'est PAS de la responsabilité de ce service.
# Il vient désormais de PropertyDpeMatrixService (moteur 3CL physique, spécifique
# au bien) — cf. Temps 3b-2. L'ancien forfait DPE_IMPACT a été supprimé.

class TravauxMapperService

  # Les 7 codes canoniques qui structurent travaux_selection sur Property.
  # Ordre important : c'est l'ordre d'affichage dans l'UI (par priorité thermique).
  CANONICAL_CODES = %w[
    isolation_toiture
    isolation_murs
    isolation_plancher_bas
    chauffage
    chauffe_eau
    vmc
    menuiseries
  ].freeze

  # Libellés courts pour l'affichage dans les cases à cocher.
  LABELS = {
    "isolation_toiture"      => "Isolation de la toiture",
    "isolation_murs"         => "Isolation des murs",
    "isolation_plancher_bas" => "Isolation des planchers bas",
    "chauffage"              => "Remplacement du chauffage",
    "chauffe_eau"            => "Chauffe-eau performant",
    "vmc"                    => "VMC double flux",
    "menuiseries"            => "Remplacement des fenêtres"
  }.freeze

  # Emojis pour l'affichage (conserve la logique visuelle de show.html.erb).
  EMOJIS = {
    "isolation_toiture"      => "🏠",
    "isolation_murs"         => "🧱",
    "isolation_plancher_bas" => "🪨",
    "chauffage"              => "🔥",
    "chauffe_eau"            => "🚿",
    "vmc"                    => "💨",
    "menuiseries"            => "🪟"
  }.freeze

  # ─── Mapping macro-poste → équipements détaillés ───────────────────
  # Pour chaque case cochée dans travaux_selection, quels équipements
  # booléens de equipements_selection doivent être pris en compte par
  # MPR Par geste / CEE.
  #
  # Les 3 isolations n'ont aucun booléen associé : leur contribution
  # passe exclusivement par les surfaces (voir MACRO_TO_SURFACES).
  MACRO_TO_EQUIPEMENTS = {
    "isolation_toiture"      => [],
    "isolation_murs"         => [],
    "isolation_plancher_bas" => [],
    "chauffage"              => %w[
      pac_air_eau pac_geothermique
      poele_buches poele_granules insert_foyer
      raccordement_reseau_chaleur depose_fioul
    ],
    "chauffe_eau"            => %w[
      chauffe_eau_thermo chauffe_eau_solaire
      systeme_solaire_combine pvt_eau
    ],
    "vmc"                    => %w[vmc_double_flux],
    "menuiseries"            => %w[nb_parois_vitrees]
  }.freeze

  # ─── Mapping macro-poste → surfaces (colonnes decimal sur Property) ─
  # Pour chaque case cochée, quelles surfaces entrent dans le calcul
  # MPR Par geste et Grand Nancy Isolation.
  MACRO_TO_SURFACES = {
    "isolation_toiture"      => %w[sarking combles_perdus toiture_terrasse],
    "isolation_murs"         => %w[ite iti],
    "isolation_plancher_bas" => %w[plancher_bas],
    "chauffage"              => [],
    "chauffe_eau"            => [],
    "vmc"                    => [],
    "menuiseries"            => []
  }.freeze

  # ─── Mapping inverse : code travaux_prevus → macro-poste ────────────
  # Utilisé par AidCalculatorService#travaux_prevus pour déterminer si
  # un "poste" déduit de la description ou des surfaces doit être filtré.
  POSTE_TO_MACRO = {
    "ite"              => "isolation_murs",
    "iti"              => "isolation_murs",
    "sarking"          => "isolation_toiture",
    "combles_perdus"   => "isolation_toiture",
    "toiture_terrasse" => "isolation_toiture",
    "plancher_bas"     => "isolation_plancher_bas",
    "vmc"              => "vmc",
    "menuiseries"      => "menuiseries"
  }.freeze

  # ─── Équipements qui restent actifs indépendamment des cases cochées ─
  # audit_energetique est un acte d'accompagnement, pas un travail
  # de rénovation : il est déclenché par l'inscription au Parcours
  # accompagné, indépendamment de quels travaux sont choisis.
  ALWAYS_ON_EQUIPEMENTS = %w[audit_energetique].freeze

  # Mappe un libellé Claude libre vers un code canonique.
  # Retourne nil si aucun match (le travail sera affiché sans checkbox).
  def self.code_for_poste(poste)
    return nil if poste.blank?
    p = poste.to_s.downcase

    return "isolation_toiture"      if p.match?(/combles|toiture|sarking|terrasse|rampants/)
    return "chauffage"               if p.match?(/chauffage|chaudière|chaudiere|pac|pompe à chaleur|poêle|poele|insert/)
    return "chauffe_eau"             if p.match?(/chauffe-eau|chauffe eau|eau chaude|ecs|ballon.*thermo|thermodynamique|solaire combiné/)
    return "vmc"                     if p.match?(/ventilation|vmc/)
    return "menuiseries"             if p.match?(/fenêtre|fenetre|vitrage|menuiserie/)
    return "isolation_plancher_bas"  if p.match?(/plancher|sous-sol|vide sanitaire|dalle|terre-plein/)
    return "isolation_murs"          if p.match?(/mur|facade|façade|ite|iti|isolation.*exterieur|isolation.*extérieur|isolation.*interieur|isolation.*intérieur/)

    nil
  end

  # Retourne la liste des codes d'équipements autorisés par un ensemble
  # de macro-postes actifs, en incluant les ALWAYS_ON_EQUIPEMENTS.
  #
  # Si macros_actifs est nil, retourne :all (pas de filtre = tout actif).
  #
  #   TravauxMapperService.equipements_for(nil)
  #     # => :all
  #   TravauxMapperService.equipements_for([])
  #     # => ["audit_energetique"]  (seulement les always-on)
  #   TravauxMapperService.equipements_for(["chauffage"])
  #     # => ["pac_air_eau", "pac_geothermique", ..., "audit_energetique"]
  def self.equipements_for(macros_actifs)
    return :all if macros_actifs.nil?
    codes = macros_actifs.to_a.map(&:to_s)
    (codes.flat_map { |c| MACRO_TO_EQUIPEMENTS[c].to_a } + ALWAYS_ON_EQUIPEMENTS).uniq
  end

  # Retourne la liste des surfaces autorisées par un ensemble de
  # macro-postes actifs.
  #
  # Si macros_actifs est nil, retourne :all.
  def self.surfaces_for(macros_actifs)
    return :all if macros_actifs.nil?
    codes = macros_actifs.to_a.map(&:to_s)
    codes.flat_map { |c| MACRO_TO_SURFACES[c].to_a }.uniq
  end

  # Retourne le macro-poste parent d'un poste déduit (ite, vmc, etc.)
  # Utilisé par AidCalculatorService#travaux_prevus pour filtrage.
  def self.macro_for_poste_prevus(poste)
    POSTE_TO_MACRO[poste.to_s]
  end
end
