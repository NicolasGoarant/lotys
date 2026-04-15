class PhotoAnalysisService
  MAX_PHOTOS = 10

  def initialize(property)
    @property = property
  end

  def call
    return unless @property.photos.attached?

    photos = @property.photos.first(MAX_PHOTOS)
    return if photos.empty?

    content = build_content(photos)
    response = call_claude(content)
    return unless response

    # Stocker le résumé photo dans l'analyse existante
    analysis = @property.analysis || @property.build_analysis
    raw = analysis.raw_response || {}
    raw["photo_analysis"] = response
    analysis.update!(raw_response: raw)

    Rails.logger.info("PhotoAnalysisService: #{photos.size} photos analysées pour property ##{@property.id}")
    response
  rescue => e
    Rails.logger.error("PhotoAnalysisService failed: #{e.message}")
    nil
  end

  private

  def build_content(photos)
    content = []
    content << {
      type: "text",
      text: "Tu es un expert en immobilier et rénovation énergétique. Analyse ces photos d'un bien immobilier (#{@property.property_type}, #{@property.surface}m², DPE #{@property.dpe_class}, construit en #{@property.construction_year}) situé à #{@property.city}. Décris en JSON : l'état général visible, les défauts constatés, les travaux prioritaires visibles, et une estimation de l'état de chaque pièce ou élément photographié. Format JSON strict : { \"etat_general\": \"...\", \"defauts\": [...], \"travaux_visibles\": [...], \"details_photos\": [...] }"
    }

    photos.each_with_index do |photo, i|
      next unless photo.content_type.start_with?("image/")
      content << {
        type: "image",
        source: {
          type: "base64",
          media_type: photo.content_type,
          data: Base64.strict_encode64(photo.download)
        }
      }
    end

    content
  end

  def call_claude(content)
    response = HTTParty.post(
      "https://api.anthropic.com/v1/messages",
      headers: {
        "x-api-key"         => ENV["ANTHROPIC_API_KEY"],
        "anthropic-version" => "2023-06-01",
        "content-type"      => "application/json"
      },
      body: {
        model:      "claude-haiku-4-5",
        max_tokens: 1000,
        messages:   [{ role: "user", content: content }]
      }.to_json,
      timeout: 60
    )

    return nil unless response.success?
    body = JSON.parse(response.body)
    text = body.dig("content", 0, "text")
    JSON.parse(text.gsub(/```json|```/, "").strip) rescue text
  end
end
