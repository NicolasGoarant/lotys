require "open3"

class DocumentAnalysisService
  ANTHROPIC_API_URL = "https://api.anthropic.com/v1/messages"
  MAX_VISION_PAGES = 4

  # Types que l'IA peut attribuer (alignés sur l'enum Document).
  # "photo" est exclu : les photos passent par PhotoAnalysisService.
  CLASSIFIABLE_TYPES = %w[dpe titre_propriete pv_ag devis autre].freeze

  def initialize(document)
    @document = document
    @property = document.property
  end

  def call
    return false unless @document.file.attached?

    text_content = extract_text

    raw =
      if text_content.present?
        call_claude_text(build_prompt(text_content))
      else
        Rails.logger.info("DocumentAnalysisService: texte vide pour doc #{@document.id}, bascule en Vision")
        images = pdf_to_images
        if images.blank?
          Rails.logger.error("DocumentAnalysisService: conversion images impossible pour doc #{@document.id}")
          return false
        end
        call_claude_vision(images)
      end

    return false if raw.blank?

    detected_type, summary = parse_classification(raw)

    attrs = { ai_summary: summary, processed: true }
    attrs[:document_type] = detected_type if detected_type
    @document.update(attrs)

    Rails.logger.info("DocumentAnalysisService: doc #{@document.id} classé '#{detected_type || @document.document_type}'")
    true
  end

  private

  # Sépare la ligne "TYPE: xxx" du reste du texte.
  # Renvoie [type_détecté_ou_nil, résumé]. Si la classification est absente ou
  # non reconnue, on ne touche pas au type existant et on garde le texte brut.
  def parse_classification(raw)
    text  = raw.to_s
    match = text.match(/^\s*TYPE\s*:\s*([a-z_]+)/i)

    if match && CLASSIFIABLE_TYPES.include?(match[1].downcase)
      summary = text.sub(/^\s*TYPE\s*:\s*[a-z_]+\s*\n?/i, "").strip
      [match[1].downcase, summary]
    else
      [nil, text.strip]
    end
  end

  # Extraction via `pdftotext -layout` (poppler-utils, cf. Aptfile).
  # Cohérent avec PropertyDataExtractorService#extract_pdf_text — même
  # outil, mêmes garanties de mise en page tabulaire.
  def extract_text
    Tempfile.create(["doc", ".pdf"]) do |tmp|
      tmp.binmode
      tmp.write(@document.file.download)
      tmp.rewind
      stdout, stderr, status = Open3.capture3("pdftotext", "-layout", tmp.path, "-")
      unless status.success?
        Rails.logger.error("pdftotext error (exit #{status.exitstatus}): #{stderr.strip}")
        return ""
      end
      stdout.strip
    end
  rescue => e
    Rails.logger.error("PDF text extraction error: #{e.message}")
    ""
  end

  def pdf_to_images
    images = []
    dir = Dir.mktmpdir("lauze_vision")

    Tempfile.create(["doc", ".pdf"]) do |tmp|
      tmp.binmode
      tmp.write(@document.file.download)
      tmp.rewind

      output_prefix = File.join(dir, "page")
      result = system("pdftoppm", "-r", "150", "-png", "-l", MAX_VISION_PAGES.to_s, tmp.path, output_prefix)

      unless result
        Rails.logger.error("pdftoppm failed for doc #{@document.id}")
        return []
      end

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

  def classification_instruction
    <<~TXT
      Commence IMPÉRATIVEMENT ta réponse par une première ligne au format exact :

      TYPE: <code>

      où <code> est l'un de : dpe, titre_propriete, pv_ag, devis, autre.
      - dpe : diagnostic de performance énergétique
      - titre_propriete : acte de vente, compromis, attestation de propriété
      - pv_ag : procès-verbal d'assemblée générale de copropriété
      - devis : devis ou facture de travaux
      - autre : tout le reste
      Choisis "autre" en cas de doute. Passe ensuite à la ligne et rédige l'analyse.
    TXT
  end

  def build_prompt(content)
    <<~PROMPT
      Tu es un expert en droit immobilier et rénovation énergétique français.
      #{classification_instruction}

      Analyse ensuite le document et fournis :

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
    <<~PROMPT
      Tu es un expert en droit immobilier et rénovation énergétique français.
      #{classification_instruction}

      Analyse ensuite ce document (images de pages PDF scannées) et fournis :

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
    content = [{ type: "text", text: build_vision_prompt }]
    base64_images.each do |img_b64|
      content << {
        type: "image",
        source: { type: "base64", media_type: "image/png", data: img_b64 }
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
