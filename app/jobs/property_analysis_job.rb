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

    # ── Proxy fioul ────────────────────────────────────────────────────
    # sync_analysis_fields vient de propager equipements["depose_fioul"]
    # depuis le JSON Claude vers Property#equipements_selection. Si ce
    # booléen est à true ET que personne (extracteur, futur DPE PDF,
    # utilisateur) n'a déjà posé une source plus fiable, on déduit
    # energie_chauffage = :fioul / source = :deduit.
    # La méthode respecte la hiérarchie : :extrait_* / :confirme_utilisateur
    # ne sont JAMAIS écrasés par ce proxy.
    property.reload.appliquer_proxy_fioul_depuis_equipements!

    # Extraction incomplète : si Claude n'a pas pu remplir surface ou
    # dpe_class à partir des documents fournis, on remet en :draft plutôt
    # qu'en :analyzed. La vue affichera un bandeau "complétez ces champs"
    # et la publication restera bloquée tant que le bien n'est pas complet.
    property.reload
    next_status = (property.surface.blank? || property.dpe_class.blank?) ? :draft : :analyzed
    property.update(status: next_status)

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
  #   2. Surfaces d'isolation (6 colonnes decimal)
  #   3. Équipements choisis (jsonb equipements_selection + nb_parois_vitrees)
  #   4. travaux_selection (jsonb) — dérivé des deux précédents pour que
  #      les cards Aides et Financement aient bien des cases cochées dès
  #      la fin de l'analyse. Préserve un choix utilisateur antérieur.
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

    persist_derived_travaux_selection(property)
  rescue => e
    Rails.logger.error("sync_analysis_fields failed: #{e.message}")
  end

  # ─── 4. Pré-remplissage server-side de travaux_selection ─────────────
  # Sans cette étape, les cards Aides et Financement affichaient des
  # états vides juste après l'analyse, alors que les équipements et
  # surfaces étaient bien posés : le JS de la card Rénovation cochait
  # les bonnes cases visuellement, mais rien n'était persisté tant que
  # l'utilisateur n'avait pas re-soumis le formulaire update_travaux_selection.
  #
  # Réutilise les mappings MACRO_TO_EQUIPEMENTS / MACRO_TO_SURFACES de
  # TravauxMapperService — pas de duplication de la table de vérité.
  #
  # update_column (et non update) : bypass des store_accessor et des
  # callbacks, comme le fait déjà update_travaux_selection dans le
  # controller (écriture atomique du hash complet).
  def persist_derived_travaux_selection(property)
    return if property.travaux_selection.present?

    derived = derive_travaux_selection(property)
    property.update_column(:travaux_selection, derived)

    actifs = derived.select { |_, v| v }.keys
    Rails.logger.info("travaux_selection dérivé: #{actifs.empty? ? 'aucun' : actifs.join(', ')}")
  end

  def derive_travaux_selection(property)
    equipements = property.equipements_selection || {}
    bool_cast   = ActiveModel::Type::Boolean.new

    TravauxMapperService::CANONICAL_CODES.each_with_object({}) do |code, h|
      equip_keys   = TravauxMapperService::MACRO_TO_EQUIPEMENTS[code]
      surface_keys = TravauxMapperService::MACRO_TO_SURFACES[code]

      equip_active = equip_keys.any? do |key|
        val = equipements[key]
        # nb_parois_vitrees est un entier (nombre de fenêtres simple→double
        # vitrage), tous les autres équipements sont des booléens.
        key == "nb_parois_vitrees" ? val.to_i > 0 : bool_cast.cast(val)
      end

      surface_active = surface_keys.any? do |key|
        property.public_send("surface_#{key}").to_f > 0
      end

      h[code] = equip_active || surface_active
    end
  end
end
