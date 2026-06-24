class PropertyDataExtractorService
  ANTHROPIC_API_URL = "https://api.anthropic.com/v1/messages"

  def initialize(property)
    @property = property
  end

  def call
    summaries = collect_document_texts

    if summaries.blank?
      sync_from_existing_analysis
      return false
    end

    extracted = extract_structured_data(summaries)
    update_property(extracted)
    true
  end

  private

  def collect_document_texts
    texts = []

    @property.documents.reload.each do |doc|
      next unless doc.file.attached?

      if doc.ai_summary.present?
        texts << "=== #{doc.document_type.humanize} ===\n#{doc.ai_summary}"
      else
        raw = extract_pdf_text(doc)
        texts << "=== #{doc.document_type.humanize} ===\n#{raw.truncate(3000)}" if raw.present?
      end
    end

    texts.join("\n\n")
  end

  def extract_pdf_text(document)
    Tempfile.create(["doc", ".pdf"]) do |tmp|
      tmp.binmode
      tmp.write(document.file.download)
      tmp.rewind
      reader = PDF::Reader.new(tmp.path)
      reader.pages.map(&:text).join("\n")
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
        "roof_insulation": <description de l'isolation de la toiture, null si inconnue>
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
