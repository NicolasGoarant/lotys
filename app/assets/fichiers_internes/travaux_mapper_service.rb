# app/services/travaux_mapper_service.rb
#
# Mappe un libellé de travail issu de l'analyse Claude vers :
#   - un code canonique (une des 7 clés de travaux_selection)
#   - un libellé affichable court
#   - un impact DPE indicatif (nombre de classes gagnées)
#
# Exemples :
#   TravauxMapperService.canonical("Isolation des rampants (sarking ou ITI)")
#     # => "isolation_toiture"
#   TravauxMapperService.code_for_poste("Remplacement du chauffage électrique par PAC air/eau")
#     # => "chauffage"
#   TravauxMapperService::DPE_IMPACT["chauffage"]
#     # => 1.5
#
# Le barème DPE est une heuristique inspirée des guides ADEME.
# Il n'est pas précis (le vrai DPE dépend d'un calcul 3CL complet), mais il
# fournit un ordre de grandeur utile à l'utilisateur pour arbitrer ses travaux.
# Un disclaimer "estimation indicative" est affiché dans la vue.

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

  # Impact DPE estimé par travail (en classes gagnées).
  # Source : heuristique inspirée des guides ADEME sur les gestes de rénovation.
  # Plafonné à 5 classes max dans les calculs (un saut F→A est irréaliste
  # sur un seul bouquet sans rénovation globale complète).
  DPE_IMPACT = {
    "isolation_toiture"      => 1.0,
    "isolation_murs"         => 1.0,
    "isolation_plancher_bas" => 0.5,
    "chauffage"              => 1.5,
    "chauffe_eau"            => 0.5,
    "vmc"                    => 0.5,
    "menuiseries"            => 0.5
  }.freeze

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

  # Total de classes DPE gagnées par un ensemble de codes cochés.
  # Plafonné à 5 pour rester dans un ordre de grandeur réaliste.
  def self.gain_dpe(codes_coches)
    total = codes_coches.to_a.sum { |code| DPE_IMPACT[code].to_f }
    [total.round, 5].min
  end
end
