class GeocodingService
  # API Adresse (BAN — Base Adresse Nationale, data.gouv.fr).
  # Avantage par rapport à Nominatim : renvoie un `citycode` officiel
  # (code INSEE de la commune), ce qui est notre clé d'appartenance à
  # un EPCI (cf. GrandNancy::COMMUNE_INSEE_CODES).
  BAN_URL = "https://api-adresse.data.gouv.fr/search/".freeze

  # En dessous de ce seuil, on considère que le match est trop faible
  # pour persister un code INSEE — l'utilisateur pourrait être attribué
  # à la mauvaise commune et perdre / gagner indûment des aides.
  # On garde lat/lng (utile à la carte) mais on laisse code_insee NULL.
  MIN_INSEE_SCORE = 0.4

  def initialize(property)
    @property = property
  end

  def call
    return if @property.lat.present? && @property.lng.present? && @property.code_insee.present?

    query = [@property.address, @property.city].compact_blank.join(" ")
    return if query.blank?

    params = { q: query, limit: 1, autocomplete: 0 }
    params[:postcode] = @property.zipcode if @property.zipcode.present?

    response = HTTParty.get(BAN_URL, query: params, timeout: 5,
                            headers: { "User-Agent" => "Lauze/1.0 contact@lauze.eu" })
    feature  = (JSON.parse(response.body) rescue {})["features"]&.first
    return Rails.logger.warn("GeocodingService: aucun match BAN pour '#{query}'") if feature.nil?

    coords = feature.dig("geometry", "coordinates") || []
    # BAN renvoie [lon, lat] (convention GeoJSON). À NE PAS inverser.
    lon, lat = coords
    return Rails.logger.warn("GeocodingService: coordonnées vides pour '#{query}'") if lat.nil? || lon.nil?

    props    = feature["properties"] || {}
    score    = props["score"].to_f
    citycode = props["citycode"]

    updates = { lat: lat.to_f, lng: lon.to_f }
    if score >= MIN_INSEE_SCORE && citycode.present?
      updates[:code_insee] = citycode
    else
      Rails.logger.warn("GeocodingService: score faible (#{score.round(2)}) pour '#{query}' → code_insee NON persisté (citycode candidat : #{citycode.inspect})")
    end

    @property.update_columns(updates)
  rescue => e
    Rails.logger.warn("GeocodingService failed: #{e.message}")
  end
end
