class DocumentAnalysisService
  ANTHROPIC_API_URL = "https://api.anthropic.com/v1/messages"

  def initialize(document)
    @document = document
    @property = document.property
  end

  def call
    text_content = extract_text
    return false if text_content.blank?

    prompt = build_prompt(text_content)
    response = call_claude(prompt)

    @document.update(ai_summary: response, processed: true)
    true
  end

  private

  def extract_text
    file = @document.file
    return "" unless file.attached?

    Tempfile.create(["doc", ".pdf"]) do |tmp|
      tmp.binmode
      tmp.write(file.download)
      tmp.rewind
      reader = PDF::Reader.new(tmp.path)
      reader.pages.map(&:text).join("\n")
    end
  rescue => e
    Rails.logger.error("PDF extraction error: #{e.message}")
    ""
  end

  def build_prompt(content)
    type_label = @document.document_type.humanize
    <<~PROMPT
      Tu es un expert en droit immobilier et rénovation énergétique français.
      Analyse ce document de type "#{type_label}" et fournis :

      1. RÉSUMÉ : Un résumé factuel en 3-5 phrases
      2. POINTS CLÉS : Les informations importantes pour le propriétaire
      3. ALERTES : Tout ce qui mérite attention (conflits en copropriété, mauvais DPE, clauses restrictives, etc.)
      4. RECOMMANDATIONS : Ce que le propriétaire devrait faire suite à ce document

      Document :
      ---
      #{content.truncate(8000)}
      ---

      Réponds en français, de façon claire et structurée.
    PROMPT
  end

  def call_claude(prompt)
    response = HTTParty.post(
      ANTHROPIC_API_URL,
      headers: {
        "Content-Type" => "application/json",
        "x-api-key" => ENV["ANTHROPIC_API_KEY"],
        "anthropic-version" => "2023-06-01"
      },
      body: {
        model: "claude-sonnet-4-6",
        max_tokens: 1024,
        messages: [{ role: "user", content: prompt }]
      }.to_json
    )
    data = JSON.parse(response.body)
    data.dig("content", 0, "text") || "Analyse indisponible"
  end
end
