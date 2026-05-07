class GeocodingService
  NOMINATIM = "https://nominatim.openstreetmap.org/search"

  def initialize(property)
    @property = property
  end

  def call
    return if @property.lat.present? && @property.lng.present?

    query = "#{@property.address}, #{@property.city}, France"
    response = HTTParty.get(NOMINATIM, query: {
      q: query, format: "json", limit: 1
    }, headers: { "User-Agent" => "Lauze/1.0 contact@lauze.eu" }, timeout: 5)

    results = JSON.parse(response.body) rescue []
    return if results.empty?

    @property.update_columns(
      lat: results.first["lat"].to_f,
      lng: results.first["lon"].to_f
    )
  rescue => e
    Rails.logger.warn("GeocodingService failed: #{e.message}")
  end
end
