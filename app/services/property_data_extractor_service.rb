require "open3"

class PropertyDataExtractorService
  ANTHROPIC_API_URL = "https://api.anthropic.com/v1/messages"

  def initialize(property)
    @property = property
  end

  def call
    bundle = collect_document_texts

    if bundle[:llm].blank?
      sync_from_existing_analysis
      return false
    end

    extracted = extract_structured_data(bundle[:llm])
    update_property(extracted)

    # Filets déterministes : si l'extraction LLM n'a pas posé la surface
    # ou l'année de construction, on tente une récupération par regex sur
    # le texte brut des documents. Ces appels doivent avoir lieu ICI, dans
    # la même passe d'analyse, AVANT toute purge du fichier
    # (cf. PropertyAnalysisJob#purge_documents).
    apply_surface_regex_fallback(bundle)           if @property.reload.surface.blank?
    apply_construction_year_regex_fallback(bundle) if @property.reload.construction_year.blank?

    true
  end

  private

  # Construit deux versions du texte en une seule passe (un seul download
  # par document) :
  #   - :llm   → ai_summary si dispo (plus court, mieux pour le prompt)
  #             sinon le texte brut PDF tronqué à 3000 chars.
  #   - :raw   → texte brut PDF systématiquement, utilisé par le filet
  #             regex (formulations canoniques préservées, pas réécrites
  #             par l'IA en amont).
  def collect_document_texts
    llm = []
    raw = []

    @property.documents.reload.each do |doc|
      next unless doc.file.attached?

      pdf_text = extract_pdf_text(doc)
      raw << "=== #{doc.document_type.humanize} ===\n#{pdf_text}" if pdf_text.present?

      if doc.ai_summary.present?
        llm << "=== #{doc.document_type.humanize} ===\n#{doc.ai_summary}"
      elsif pdf_text.present?
        llm << "=== #{doc.document_type.humanize} ===\n#{pdf_text.truncate(3000)}"
      end
    end

    { llm: llm.join("\n\n"), raw: raw.join("\n\n") }
  end

  def apply_surface_regex_fallback(bundle)
    source = [bundle[:raw], bundle[:llm]].reject(&:blank?).join("\n\n")
    surface = SurfaceRegexFallback.call(source)
    return unless surface

    @property.update(surface: surface)
    Rails.logger.info("PropertyDataExtractor: filet regex a comblé surface=#{surface} m²")
  end

  def apply_construction_year_regex_fallback(bundle)
    source = [bundle[:raw], bundle[:llm]].reject(&:blank?).join("\n\n")
    year   = ConstructionYearRegexFallback.call(source)
    return unless year

    @property.update(construction_year: year)
    Rails.logger.info("PropertyDataExtractor: filet regex a comblé construction_year=#{year}")
  end

  # Extraction via `pdftotext -layout` (poppler-utils).
  # -layout préserve l'alignement tabulaire des DPE : le libellé et la
  # valeur restent sur la même ligne quand c'est le cas dans le PDF
  # source, ce qui bénéficie autant à l'extraction LLM qu'aux filets
  # regex en aval. `-` en sortie envoie sur stdout.
  # Dépendance système : poppler-utils (cf. Aptfile pour Heroku).
  def extract_pdf_text(document)
    Tempfile.create(["doc", ".pdf"]) do |tmp|
      tmp.binmode
      tmp.write(document.file.download)
      tmp.rewind
      stdout, stderr, status = Open3.capture3("pdftotext", "-layout", tmp.path, "-")
      unless status.success?
        Rails.logger.error("pdftotext error (exit #{status.exitstatus}): #{stderr.strip}")
        return ""
      end
      stdout
    end
  rescue => e
    Rails.logger.error("PDF extraction error: #{e.message}")
    ""
  end

  def extract_structured_data(content)
    prompt = <<~PROMPT
      Tu es un expert immobilier français. Tu extrais des données structurées
      d'un dossier de bien immobilier.

      PRIORITÉ 1 — SURFACE HABITABLE (champ critique pour tout le reste de l'app).
      Cherche dans cet ordre :
        a) "Surface habitable Loi Carrez" ou "Loi Boutin" dans le titre de propriété ;
        b) "Surface habitable" dans le DPE ;
        c) toute mention "<N> m²" explicitement rattachée AU LOGEMENT
           (pas aux travaux, pas à un comparable, pas à un kWh/m²).
      Renvoie un entier en m². Si plusieurs valeurs cohérentes (±2 m²), prends
      celle du DPE. Si rien d'écrit explicitement → null. NE DEVINE JAMAIS.

      PRIORITÉ 2 — ANNÉE DE CONSTRUCTION (champ critique pour la matrice
      de projection DPE et pour les aides conditionnées à l'ancienneté).
      Cherche dans cet ordre :
        a) "Année de construction" dans le DPE ;
        b) "Date de construction" ou "Année de construction" dans le titre
           de propriété ;
        c) mention "construit(e) en <année>" dans un document officiel.
      Renvoie un entier à 4 chiffres. NE CONFONDS JAMAIS avec :
        - une date de facture, d'acte notarié, de bail, d'AG copro ;
        - une année de réhabilitation ou de travaux ("réhabilité en 1985") ;
        - un millésime de loi ("Loi Carrez 1996").
      Si plusieurs valeurs cohérentes (±2 ans), prends celle du DPE. Si
      rien d'écrit explicitement → null. NE DEVINE JAMAIS.

      PRIORITÉ 3 — ADRESSE DU BIEN (extraction pour le parcours "adresse
      facultative" : l'utilisateur peut avoir soumis le formulaire sans
      saisir l'adresse s'il fournit un document — on la déduit ici, puis
      il la CONFIRMERA dans l'interface).
      Hiérarchie STRICTE (source la plus fiable en premier) :
        a) DPE — "Adresse du bien diagnostiqué" ou en-tête d'identification
           du logement. C'est l'adresse DU BIEN, jamais celle du diagnostiqueur.
        b) Titre de propriété — bloc "désignation du bien" ou "situation
           du bien". Jamais l'adresse du propriétaire vendeur/acquéreur.
        c) Facture énergie — UNIQUEMENT le champ "lieu de consommation"
           ou "adresse du point de livraison". JAMAIS l'adresse de
           facturation / du titulaire, qui peut être différente.
      Renseigne "address_source" avec la source retenue ("dpe",
      "titre_propriete" ou "facture"). Si plusieurs documents donnent des
      adresses DIFFÉRENTES pour le bien (autre rue, autre commune) → null
      partout. En cas de doute, null — l'utilisateur pourra saisir
      manuellement. NE DEVINE JAMAIS depuis le nom d'une copropriété
      ou une mention de quartier.

      PRIORITÉ 4 — POSITION DU LOT DANS L'IMMEUBLE (appartements seulement).
      Cherche dans le DPE ou l'acte notarié une mention explicite du niveau
      du lot. Le champ "étage" est présent sur la plupart des DPE
      d'appartements (rubrique identification du logement).
      Valeurs autorisées (mapping strict) :
        - "dernier_etage"       : lot en dernier étage sous toiture
                                  (mention "dernier étage", "sous toit",
                                  ou étage = nombre d'étages du bâtiment).
        - "etage_intermediaire" : étage entre le RDC et le dernier étage
                                  (mention "1er étage", "2e étage", etc.,
                                  quand le bâtiment en a strictement plus).
        - "rdc"                 : rez-de-chaussée (mention "RDC", "rez-de-
                                  chaussée", "étage 0").
        - null                  : pas d'information fiable dans les documents.
      NE DEVINE JAMAIS depuis un nom de rue, une photo, ou une adresse
      qui contient un numéro. Un DPE de maison → null (champ non applicable).
      Un DPE d'appartement sans mention explicite de l'étage → null.

      Documents :
      ---
      #{content.truncate(10000)}
      ---

      Réponds UNIQUEMENT avec un objet JSON valide (sans markdown, sans commentaires) :
      {
        "surface": <entier m² ou null — voir PRIORITÉ 1>,
        "construction_year": <année entière, null si inconnue>,
        "dpe_class": <"A","B","C","D","E","F" ou "G", null si inconnu>,
        "dpe_value": <valeur kWhEP/m².an en entier, null si inconnue>,
        "property_type": <"appartement" ou "maison", null si inconnu>,
        "nb_rooms": <nombre entier de pièces, null si inconnu>,
        "nb_lots": <nombre entier de lots en copropriété, null si inconnu>,
        "is_copropriete": <true ou false>,
        "purchase_price": <prix d'achat en euros entier, null si inconnu>,
        "heating_system": <description courte du système de chauffage, null si inconnu>,
        "wall_insulation": <description de l'isolation des murs, null si inconnue>,
        "roof_insulation": <description de l'isolation de la toiture, null si inconnue>,
        "address": <ligne 1 de l'adresse du bien, null si inconnue — voir PRIORITÉ 3>,
        "city": <ville du bien, null si inconnue — voir PRIORITÉ 3>,
        "zipcode": <code postal 5 chiffres du bien, null si inconnu — voir PRIORITÉ 3>,
        "address_source": <"dpe", "titre_propriete", "facture" ou null si aucune source fiable>,
        "position_lot": <"dernier_etage", "etage_intermediaire", "rdc" ou null si inconnue — voir PRIORITÉ 4 ; toujours null pour une maison>
      }

      Priorité aux données officielles (DPE, acte notarié, certificat Carrez).
      Ne mets jamais de valeur inventée — préfère null.
    PROMPT

    response = call_claude(prompt)
    # Strip d'un éventuel ```json … ``` autour de la réponse — mode de panne
    # observé en prod (cf. logs "unexpected character: '```json'" historiques).
    cleaned = response.to_s.gsub(/\A```json\n?|```\z/, "").strip
    JSON.parse(cleaned)
  rescue JSON::ParserError => e
    Rails.logger.error("PropertyDataExtractor JSON parse error: #{e.message}\nRaw: #{response}")
    {}
  end

  def update_property(data)
    return if data.blank?

    updates = {}

    updates[:surface]           = data["surface"]           if @property.surface.blank?           && data["surface"].present?
    updates[:construction_year] = data["construction_year"] if @property.construction_year.blank? && data["construction_year"].present?
    updates[:dpe_class]         = data["dpe_class"]         if @property.dpe_class.blank?         && data["dpe_class"].present?
    updates[:nb_rooms]          = data["nb_rooms"]          if @property.nb_rooms.blank?          && data["nb_rooms"].present?
    updates[:nb_lots]           = data["nb_lots"]           if @property.nb_lots.blank?           && data["nb_lots"].present?

    if @property.property_type.blank? && data["property_type"].present?
      type = data["property_type"].downcase
      updates[:property_type] = type if Property.property_types.key?(type)
    end

    updates[:is_copropriete] = true if data["is_copropriete"] == true

    # ── Adresse détectée (C3) ─────────────────────────────────────────
    # Ne s'exécute QUE si Property#address est vide (parcours "documents
    # sans adresse" — C2). Dépose exclusivement dans les colonnes
    # _detected, JAMAIS dans address/city/zipcode : le principe "pas
    # d'analyse sur hypothèse non validée" impose une confirmation
    # utilisateur (bandeau à la vue résultats, C5). address_confirmed_at
    # reste NULL — seul un clic explicite le pose.
    #
    # Exigences :
    #   - les trois champs (address+city+zipcode) présents,
    #   - zipcode 5 chiffres (protège des "12345 " ou "NC" que le LLM
    #     pourrait renvoyer si le doc est confus),
    #   - address_source dans la liste blanche des sources d'extraction
    #     ("manuel" est réservé au controller — jamais issu du LLM).
    if @property.address.blank? &&
       data["address"].present? && data["city"].present? && data["zipcode"].present? &&
       data["zipcode"].to_s =~ /\A\d{5}\z/ &&
       %w[dpe titre_propriete facture].include?(data["address_source"])

      updates[:address_detected]  = data["address"].to_s.strip
      updates[:city_detected]     = data["city"].to_s.strip
      updates[:zipcode_detected]  = data["zipcode"].to_s.strip
      updates[:address_source]    = data["address_source"]
    end

    # ── Position du lot (appartements) ────────────────────────────────
    # On dépose EXCLUSIVEMENT dans position_lot_detected, jamais dans
    # position_lot : même discipline que pour l'adresse (pas d'analyse
    # sur hypothèse non validée). L'utilisateur confirme via
    # PropertiesController#confirm_position_lot, ce qui pose
    # position_lot + position_lot_confirmed_at.
    # Whitelist stricte des valeurs — le LLM peut renvoyer "1er étage"
    # ou "sous les combles" qui ne sont pas dans le mapping ; on ne
    # persiste que les 3 valeurs canoniques (le reste → l'utilisateur
    # devra choisir dans le bandeau).
    if Property::POSITIONS_LOT.include?(data["position_lot"].to_s) &&
       data["position_lot"].to_s != "inconnu" &&
       @property.position_lot_detected.blank?
      updates[:position_lot_detected] = data["position_lot"].to_s
    end

    # ── Capture structurée de l'énergie de chauffage ──────────────────
    # heating_system est déjà parsé en JSON par extract_structured_data.
    # On le normalise via HeatingEnergyNormalizer (source de vérité unique)
    # et on écrit en colonne typée Property#energie_chauffage. La hiérarchie
    # de confiance protège un :extrait_dpe ou un :confirme_utilisateur
    # déjà posé contre l'écrasement (cf. Property.upgrade_energie_source?).
    # NB : on garde EN PARALLÈLE l'écriture historique dans description
    # (texte libre) — pas de régression sur l'affichage existant.
    if data["heating_system"].present?
      energie = HeatingEnergyNormalizer.call(data["heating_system"])
      if energie != :inconnue &&
         Property.upgrade_energie_source?(@property.energie_chauffage_source, "extrait_description")
        updates[:energie_chauffage]        = energie.to_s
        updates[:energie_chauffage_source] = "extrait_description"
      end
    end

    if @property.description.blank?
      extras = []
      extras << "Chauffage : #{data['heating_system']}"       if data["heating_system"].present?
      extras << "Isolation murs : #{data['wall_insulation']}" if data["wall_insulation"].present?
      extras << "Isolation toiture : #{data['roof_insulation']}" if data["roof_insulation"].present?
      extras << "Prix d'acquisition : #{data['purchase_price']} €" if data["purchase_price"].present?
      updates[:description] = extras.join(" | ") if extras.any?
    end

    if updates.any?
      @property.update(updates)
      Rails.logger.info("PropertyDataExtractor updated: #{updates.keys.join(', ')}")
    end
  end

  # Fallback : si aucun document n'a d'ai_summary,
  # récupère le profil_extrait depuis l'analyse IA existante
  def sync_from_existing_analysis
    return unless @property.analysis&.content.present?
    json = JSON.parse(@property.analysis.content) rescue nil
    return unless json
    profil = json["profil_extrait"] || {}
    update_property(profil.transform_keys(&:to_s))
  end

  def call_claude(prompt)
    response = HTTParty.post(
      ANTHROPIC_API_URL,
      headers: {
        "Content-Type"      => "application/json",
        "x-api-key"         => ENV["ANTHROPIC_API_KEY"],
        "anthropic-version" => "2023-06-01"
      },
      body: {
        model:     "claude-sonnet-4-6",
        max_tokens: 1024,
        messages:  [{ role: "user", content: prompt }]
      }.to_json
    )
    JSON.parse(response.body).dig("content", 0, "text")
  end
end
