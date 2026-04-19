class PropertyAnalysisJob < ApplicationJob
  queue_as :analysis

  # Colonnes de surface (decimal) à synchroniser depuis quantites_mpr
  SURFACE_COLS = %w[
    surface_ite surface_iti surface_sarking
    surface_combles_perdus surface_toiture_terrasse surface_plancher_bas
  ].freeze

  # Équipements (booléens) à synchroniser depuis quantites_mpr.equipements
  EQUIPEMENT_BOOLS = %w[
    pac_air_eau pac_geothermique
    chauffe_eau_thermo chauffe_eau_solaire
    systeme_solaire_combine pvt_eau
    poele_buches poele_granules insert_foyer
    raccordement_reseau_chaleur depose_fioul
    vmc_double_flux audit_energetique
  ].freeze

  def perform(property_id)
    property = Property.find(property_id)

    property.update(status: :analyzing)
    GeocodingService.new(property).call
    PhotoAnalysisService.new(property).call if property.photos.attached?

    property.documents.each do |doc|
      DocumentAnalysisService.new(doc).call if doc.file.attached?
    end

    PropertyDataExtractorService.new(property).call
    DvfEstimationService.new(property).call
    DeviceSimulationService.new(property).call
    PropertyAnalysisService.new(property).call
    LocalAidCalculator.new(property).call
    sync_analysis_fields(property)

    property.update(status: :analyzed)

  rescue => e
    Rails.logger.error("PropertyAnalysisJob ##{property_id} failed: #{e.message}")
    property&.update(status: :draft)
    raise
  end

  private

  # Sync des champs depuis le JSON d'analyse Claude vers les colonnes dédiées.
  # 4 groupes :
  #   1. DPE (dpe_class, dpe_target) — si non renseignés par l'utilisateur
  #   2. Surfaces d'isolation (6 colonnes decimal) pour MPR Par geste détaillé
  #   3. Équipements choisis (jsonb equipements_selection + nb_parois_vitrees)
  #   4. Travaux à réaliser (jsonb travaux_selection) — 7 cases à cocher macro
  def sync_analysis_fields(property)
    return unless property.analysis&.content.present?
    parsed = JSON.parse(property.analysis.content) rescue nil
    return unless parsed

    updates = {}

    # ---- 1. DPE ----
    if property.dpe_target.blank?
      dpe_cible = parsed.dig("energie", "dpe_cible")&.upcase
      updates[:dpe_target] = dpe_cible if dpe_cible.in?(%w[A B C D E F G])
    end
    if property.dpe_class.blank?
      dpe_estime = parsed.dig("energie", "dpe_estime")&.upcase
      updates[:dpe_class] = dpe_estime if dpe_estime.in?(%w[A B C D E F G])
    end

    # ---- 2. Surfaces (MPR Par geste) ----
    quantites = parsed["quantites_mpr"] || {}
    SURFACE_COLS.each do |col|
      next unless property.send(col).to_f.zero?  # ne pas écraser une saisie utilisateur
      val = quantites[col]
      updates[col.to_sym] = val if val.is_a?(Numeric) && val >= 0
    end

    nb_vitrees = quantites["nb_parois_vitrees"]
    nb_vitrees_value = nb_vitrees.is_a?(Numeric) && nb_vitrees >= 0 ? nb_vitrees.to_i : nil

    # ---- 3. Équipements (jsonb equipements_selection) ----
    equipements = (quantites["equipements"] || {}).slice(*EQUIPEMENT_BOOLS)
    existing_equip = property.equipements_selection || {}
    merged_equip   = existing_equip.dup
    equipements.each do |k, v|
      next if existing_equip.key?(k)
      merged_equip[k] = !!v
    end
    merged_equip["nb_parois_vitrees"] = nb_vitrees_value if nb_vitrees_value && !existing_equip.key?("nb_parois_vitrees")
    updates[:equipements_selection] = merged_equip if merged_equip != existing_equip

    # ---- 4. Travaux à réaliser (jsonb travaux_selection) ----
    # Pour chaque travail proposé par Claude, on mappe vers un code canonique
    # et on pré-coche la case correspondante. On préserve les choix utilisateur
    # existants (une case déjà explicitement à true/false n'est pas écrasée).
    travaux_claude = parsed.dig("energie", "travaux") || []
    existing_travaux = property.travaux_selection || {}
    merged_travaux = existing_travaux.dup

    travaux_claude.each do |t|
      code = TravauxMapperService.code_for_poste(t["poste"])
      next unless code
      next if existing_travaux.key?(code)  # respecte choix utilisateur antérieur
      merged_travaux[code] = true
    end

    updates[:travaux_selection] = merged_travaux if merged_travaux != existing_travaux

    property.update(updates) if updates.any?
    Rails.logger.info("sync_analysis_fields updated: #{updates.keys.join(', ')}")
  rescue => e
    Rails.logger.error("sync_analysis_fields failed: #{e.message}")
  end
end
