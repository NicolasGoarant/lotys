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
  # 4 groupes :
  #   1. DPE (dpe_class, dpe_target) — si non renseignés par l'utilisateur
  #   2. Surfaces d'isolation (6 colonnes decimal) pour MPR Par geste détaillé
  #   3. Équipements choisis (jsonb equipements_selection + nb_parois_vitrees)
  #   4. Travaux à réaliser (jsonb travaux_selection) — 7 cases à cocher macro
  def sync_analysis_fields(property)
    # ... [le reste de votre méthode sync_analysis_fields existante,
    #      inchangée — je n'ai pas tout le code dans le bundle]
  end
end
