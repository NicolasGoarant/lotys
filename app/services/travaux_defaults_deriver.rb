# app/services/travaux_defaults_deriver.rb
#
# Comble la divergence entre le formulaire "7 cases macro" et les colonnes
# structurées (surface_*, equipements_selection) qu'attend AidCalculatorService.
#
# Quand l'utilisateur coche une case macro dans la card "Rénovation énergétique"
# (isolation_toiture, isolation_murs, vmc, chauffage…) mais que l'analyse Claude
# n'a pas pu remplir les colonnes structurées détaillées, le service tombe sur
# travaux_prevus vide → eligible_parcours_accompagne? false → toutes les
# branches d'aide rendent 0. Résultat affiché : "Aucune aide retenue".
#
# Cette classe dépose des ESTIMATIONS PAR DÉFAUT (jamais des mesures) sur les
# colonnes structurées correspondant aux macros cochés, uniquement là où aucune
# donnée mesurée n'est déjà présente. Elle pose un drapeau
# equipements_selection["inputs_estimes"] = true qui permet à la vue d'afficher
# honnêtement "estimation, lancez l'analyse pour affiner" plutôt que de présenter
# un montant comme certain.
#
# Règle de priorité (impérative) :
#   - Mesure Claude / saisie utilisateur > estimation par défaut.
#   - Le déricteur ne touche JAMAIS à une surface > 0 ou à un équipement déjà
#     positionné dans equipements_selection. Aucune mesure n'est écrasée.
#
# Mode persisté vs in-memory :
#   - record.persisted? : écriture via update_column par colonne (bypass des
#     callbacks et store_accessor, comme update_travaux_selection le fait déjà).
#   - record non sauvegardé (tests de services) : écriture via les setters
#     store_accessor existants. Le caller reste responsable de save / update.
#
# ─── À NE PAS FAIRE ICI ─────────────────────────────────────────────────────
# Note pour la suite (piste (ii), volontairement reportée) :
# Le vrai chantier est de refactorer AidCalculatorService pour que les 7 macros
# cochés deviennent la SOURCE DE VÉRITÉ d'éligibilité (notamment
# eligible_parcours_accompagne?, calculate_grand_nancy_isolation et
# calculate_mpr_par_geste_and_cee), et que les colonnes structurées ne servent
# qu'à affiner les forfaits quand elles sont disponibles. Ce déricteur est un
# shim transitoire : il évite "Aucune aide retenue" sans toucher au service,
# mais propage une fiction (des surfaces estimées) jusqu'au moteur de calcul.
class TravauxDefaultsDeriver
  # Heuristiques surface des postes par défaut, en multiplicateur de la
  # surface habitable au sol. Valeurs prudentes, cohérentes avec un pavillon
  # individuel carré (côté ~10 m, hauteur 2,5 m → murs ≈ surface au sol).
  SURFACE_DEFAULTS_RATIO = {
    "combles_perdus" => 1.0,
    "ite"            => 1.0,
    "plancher_bas"   => 1.0
  }.freeze

  # Pour chaque macro coché, le poste structuré sur lequel on dépose
  # l'estimation par défaut. Un seul poste par macro pour éviter la double
  # comptabilisation (ex. ITE + ITI sur "isolation_murs").
  MACRO_TO_DEFAULT_SURFACE = {
    "isolation_toiture"      => "combles_perdus",
    "isolation_murs"         => "ite",
    "isolation_plancher_bas" => "plancher_bas"
  }.freeze

  # Équipement booléen par défaut pour chaque macro non-isolation.
  # Choix cohérent avec les forfaits MPR Par geste : équipement courant en
  # rénovation, présent dans les grilles MPR_PAR_GESTE_FORFAITS et CEE_FORFAITS.
  MACRO_TO_DEFAULT_EQUIPEMENT = {
    "chauffage"   => "pac_air_eau",
    "chauffe_eau" => "chauffe_eau_thermo",
    "vmc"         => "vmc_double_flux"
  }.freeze

  # Fenêtres simple → double vitrage : approximation 1 fenêtre / 25 m²,
  # plancher 4 fenêtres pour garantir un calcul CEE/MPR non nul.
  NB_VITREES_RATIO_M2 = 25.0
  NB_VITREES_PLANCHER = 4

  def initialize(property)
    @p = property
  end

  # Dépose les estimations par défaut sur les colonnes structurées vides
  # correspondant aux macros cochés. Retourne true si au moins une estimation
  # a été ajoutée (signal pour le caller / les tests).
  def call!
    actifs = @p.travaux_actifs
    return false if actifs.empty?

    surface_changes    = surface_defaults_for(actifs)
    equipement_changes = equipement_defaults_for(actifs)
    nb_vitrees         = nb_vitrees_default_for(actifs)

    return false if surface_changes.empty? && equipement_changes.empty? && nb_vitrees.nil?

    if @p.persisted?
      apply_persisted(surface_changes, equipement_changes, nb_vitrees)
    else
      apply_in_memory(surface_changes, equipement_changes, nb_vitrees)
    end

    true
  end

  private

  # Écriture DB : update_column par colonne pour bypass callbacks et
  # garantir un commit atomique du jsonb merge.
  def apply_persisted(surface_changes, equipement_changes, nb_vitrees)
    surface_changes.each { |col, val| @p.update_column(col, val) }

    new_eq = (@p.equipements_selection || {}).dup
    equipement_changes.each { |k, v| new_eq[k] = v }
    new_eq["nb_parois_vitrees"] = nb_vitrees if nb_vitrees
    new_eq["inputs_estimes"]    = true
    @p.update_column(:equipements_selection, new_eq)
  end

  # Écriture in-memory via setters (utilisé par les tests qui construisent
  # une Property sans sauvegarder).
  def apply_in_memory(surface_changes, equipement_changes, nb_vitrees)
    surface_changes.each   { |col, val|  @p.send("#{col}=", val) }
    equipement_changes.each { |code, val| @p.send("#{code}=", val) }
    @p.nb_parois_vitrees = nb_vitrees if nb_vitrees

    eq = (@p.equipements_selection || {}).dup
    eq["inputs_estimes"] = true
    @p.equipements_selection = eq
  end

  # Pour chaque macro d'isolation coché, si TOUTES les surfaces de la famille
  # sont à 0, on dépose une estimation sur la surface "représentative" du macro.
  # Si UNE des surfaces de la famille est déjà mesurée (> 0), on ne touche rien
  # — la mesure existante a la priorité absolue.
  def surface_defaults_for(actifs)
    base = @p.surface.to_f
    return {} if base <= 0

    actifs.each_with_object({}) do |macro, h|
      poste = MACRO_TO_DEFAULT_SURFACE[macro]
      next unless poste

      family = TravauxMapperService::MACRO_TO_SURFACES[macro] || [poste]
      next if family.any? { |key| @p.send("surface_#{key}").to_f > 0 }

      col = "surface_#{poste}"
      next unless @p.respond_to?(col)

      ratio = SURFACE_DEFAULTS_RATIO[poste] || 1.0
      h[col.to_sym] = (base * ratio).round(2)
    end
  end

  # Pour chaque macro chauffage / chauffe_eau / vmc coché, si AUCUN équipement
  # de la famille n'est déjà à true côté Claude/user, on dépose le default.
  # Préserve toute valeur antérieure (true ou false) : ne sert qu'à remplir
  # le vide.
  def equipement_defaults_for(actifs)
    existing = @p.equipements_selection || {}

    actifs.each_with_object({}) do |macro, h|
      code = MACRO_TO_DEFAULT_EQUIPEMENT[macro]
      next unless code

      family = TravauxMapperService::MACRO_TO_EQUIPEMENTS[macro] || [code]
      next if family.any? { |key| existing[key] == true }

      h[code] = true
    end
  end

  # Pour le macro "menuiseries", on dépose un nombre par défaut de fenêtres
  # simple→double vitrage uniquement si nb_parois_vitrees est nul.
  def nb_vitrees_default_for(actifs)
    return nil unless actifs.include?("menuiseries")
    existing = @p.equipements_selection || {}
    return nil if existing["nb_parois_vitrees"].to_i > 0

    base = @p.surface.to_f
    base > 0 ? [(base / NB_VITREES_RATIO_M2).round, NB_VITREES_PLANCHER].max : NB_VITREES_PLANCHER
  end
end
