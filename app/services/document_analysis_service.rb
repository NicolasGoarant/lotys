class DocumentAnalysisService
  ANTHROPIC_API_URL = "https://api.anthropic.com/v1/messages"
  MAX_VISION_PAGES = 4

  def initialize(document)
    @document = document
    @property = document.property
  end

  def call
    return false unless @document.file.attached?

    text_content = extract_text

    if text_content.present?
      response = call_claude_text(build_prompt(text_content))
    else
      # PDF scanné : fallback Vision
      Rails.logger.info("DocumentAnalysisService: texte vide pour doc #{@document.id}, bascule en Vision")
      images = pdf_to_images
      if images.blank?
        Rails.logger.error("DocumentAnalysisService: impossible de convertir doc #{@document.id} en images")
        return false
      end
      response = call_claude_vision(images)
    end

    return false if response.blank?

    @document.update(ai_summary: response, processed: true)
    true
  end

  private

  def extract_text
    Tempfile.create(["doc", ".pdf"]) do |tmp|
      tmp.binmode
      tmp.write(@document.file.download)
      tmp.rewind
      reader = PDF::Reader.new(tmp.path)
      reader.pages.map(&:text).join("\n").strip
    end
  rescue => e
    Rails.logger.error("PDF text extraction error: #{e.message}")
    ""
  end

  def pdf_to_images
    images = []
    dir = Dir.mktmpdir("lotys_vision")

    Tempfile.create(["doc", ".pdf"]) do |tmp|
      tmp.binmode
      tmp.write(@document.file.download)
      tmp.rewind

      # pdftoppm converti chaque page en PNG (resolution 150 dpi)
      output_prefix = File.join(dir, "page")
      result = system("pdftoppm", "-r", "150", "-png", "-l", MAX_VISION_PAGES.to_s, tmp.path, output_prefix)

      unless result
        Rails.logger.error("pdftoppm failed for doc #{@document.id}")
        return []
      end

      # Récupère les pages générées, dans l'ordre
      Dir.glob("#{output_prefix}-*.png").sort.first(MAX_VISION_PAGES).each do |png_path|
        images << Base64.strict_encode64(File.binread(png_path))
      end
    end

    images
  rescue => e
    Rails.logger.error("PDF to images error: #{e.message}")
    []
  ensure
    FileUtils.remove_entry(dir) if dir && Dir.exist?(dir)
  end

  def build_prompt(content)
    type_label = @document.document_type.humanize
    <<~PROMPT
      Tu es un expert en droit immobilier et rénovation énergétique français.
      Analyse ce document de type "#{type_label}" et fournis :

      1. RÉSUMÉ : Un résumé factuel en 3-5 phrases
      2. POINTS CLÉS : Les informations importantes pour le propriétaire (surface, DPE, année construction, prix, etc.)
      3. ALERTES : Tout ce qui mérite attention (mauvais DPE, clauses restrictives, copropriété, etc.)
      4. RECOMMANDATIONS : Ce que le propriétaire devrait faire suite à ce document

      Document :
      ---
      #{content.truncate(8000)}
      ---
      Réponds en français, de façon claire et structurée.
    PROMPT
  end

  def build_vision_prompt
    type_label = @document.document_type.humanize
    <<~PROMPT
      Tu es un expert en droit immobilier et rénovation énergétique français.
      Analyse ce document de type "#{type_label}" (images de pages PDF scannées) et fournis :

      1. RÉSUMÉ : Un résumé factuel en 3-5 phrases
      2. POINTS CLÉS : Les informations importantes pour le propriétaire. Pour un DPE, extrais impérativement :
         - Surface habitable (m²)
         - Classe énergétique (A à G)
         - Valeur en kWhEP/m².an
         - Année ou période de construction
         - Type de bien (maison, appartement)
         - Système de chauffage
      3. ALERTES : Tout ce qui mérite attention
      4. RECOMMANDATIONS : Ce que le propriétaire devrait faire

      Réponds en français, de façon claire et structurée.
    PROMPT
  end

  def call_claude_text(prompt)
    response = HTTParty.post(
      ANTHROPIC_API_URL,
      headers: {
        "Content-Type"      => "application/json",
        "x-api-key"         => ENV["ANTHROPIC_API_KEY"],
        "anthropic-version" => "2023-06-01"
      },
      body: {
        model:      "claude-sonnet-4-6",
        max_tokens: 1024,
        messages:   [{ role: "user", content: prompt }]
      }.to_json
    )
    JSON.parse(response.body).dig("content", 0, "text") || ""
  rescue => e
    Rails.logger.error("Claude text call error: #{e.message}")
    ""
  end

  def call_claude_vision(base64_images)
    content = []

    # On ajoute le prompt texte en premier
    content << { type: "text", text: build_vision_prompt }

    # Puis chaque page comme image
    base64_images.each do |img_b64|
      content << {
        type: "image",
        source: {
          type:       "base64",
          media_type: "image/png",
          data:       img_b64
        }
      }
    end

    response = HTTParty.post(
      ANTHROPIC_API_URL,
      headers: {
        "Content-Type"      => "application/json",
        "x-api-key"         => ENV["ANTHROPIC_API_KEY"],
        "anthropic-version" => "2023-06-01"
      },
      body: {
        model:      "claude-sonnet-4-6",
        max_tokens: 1024,
        messages:   [{ role: "user", content: content }]
      }.to_json
    )
    JSON.parse(response.body).dig("content", 0, "text") || ""
  rescue => e
    Rails.logger.error("Claude vision call error: #{e.message}")
    ""
  end
end
