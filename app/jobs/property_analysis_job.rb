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

    # ─────────────────────────────────────────────────────────────────
    # Purge des documents juridiques après extraction.
    #
    # Les pages /properties/new et la page Confidentialité promettent
    # explicitement à l'utilisateur que ses documents sont supprimés
    # après l'analyse. Cette ligne honore cette promesse.
    #
    # Périmètre : seuls les Documents (DPE, titre de propriété, PV
    # d'AG, devis) sont purgés. Les Property#photos sont conservées
    # car elles servent d'illustration sur la fiche publique du bien
    # une fois publié.
    #
    # purge_later : suppression asynchrone via Active Job — ne bloque
    # pas la fin du job courant et survit à un échec ponctuel du
    # service de stockage (retry géré par ActiveJob).
    #
    # Placée APRÈS le passage en :analyzed pour que l'utilisateur voie
    # son rapport disponible immédiatement, indépendamment du temps de
    # purge effective côté S3.
    # ─────────────────────────────────────────────────────────────────
    purge_documents(property)

  rescue => e
    Rails.logger.error("PropertyAnalysisJob ##{property_id} failed: #{e.message}")
    property&.update(status: :draft)
    raise
  end

  private

  # Purge les fichiers attachés aux Documents du bien.
  # Les enregistrements Document eux-mêmes restent (ils gardent leur
  # document_type pour la traçabilité), mais leur attachment :file est
  # détaché et le blob supprimé du stockage.
  def purge_documents(property)
    property.documents.each do |doc|
      doc.file.purge_later if doc.file.attached?
    end
    Rails.logger.info("[PropertyAnalysisJob ##{property.id}] documents purgés (#{property.documents.count} fichiers)")
  rescue => e
    # On ne fait pas remonter une erreur de purge : l'analyse est
    # terminée, l'utilisateur a son résultat. On loggue pour le suivi.
    Rails.logger.error("[PropertyAnalysisJob ##{property.id}] purge documents échouée : #{e.message}")
  end

  # Sync des champs depuis le JSON d'analyse Claude vers les colonnes dédiées.
  # 3 groupes :
  #   1. DPE (dpe_class, dpe_target) — si non renseignés par l'utilisateur
  #   2. Surfaces d'isolation (6 colonnes decimal)
  #   3. Équipements choisis (jsonb equipements_selection + nb_parois_vitrees)
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

    # nb_parois_vitrees : stocké dans equipements_selection (integer)
    nb_vitrees = quantites["nb_parois_vitrees"]
    nb_vitrees_value = nb_vitrees.is_a?(Numeric) && nb_vitrees >= 0 ? nb_vitrees.to_i : nil

    # ---- 3. Équipements (jsonb) ----
    equipements = (quantites["equipements"] || {}).slice(*EQUIPEMENT_BOOLS)
    # On préserve les choix utilisateur existants et on ne remplit que les clés encore vides
    existing = property.equipements_selection || {}
    merged   = existing.dup
    equipements.each do |k, v|
      next if existing.key?(k)  # respect de la saisie utilisateur antérieure
      merged[k] = !!v
    end
    merged["nb_parois_vitrees"] = nb_vitrees_value if nb_vitrees_value && !existing.key?("nb_parois_vitrees")

    updates[:equipements_selection] = merged if merged != existing

    property.update(updates) if updates.any?
    Rails.logger.info("sync_analysis_fields updated: #{updates.keys.join(', ')}")
  rescue => e
    Rails.logger.error("sync_analysis_fields failed: #{e.message}")
  end
end
