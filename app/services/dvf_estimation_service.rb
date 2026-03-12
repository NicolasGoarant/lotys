class DvfEstimationService
  DVF_API = "https://api.cquest.org/dvf"

  def initialize(property)
    @property = property
  end

  def call
    results = fetch_comparable_sales
    return false if results.empty?

    prices_per_sqm = results.filter_map do |r|
      next if r["surface_reelle_bati"].to_f.zero?
      price = r["valeur_fonciere"].to_f / r["surface_reelle_bati"].to_f
      price if price > 500 && price < 15_000
    end

    return false if prices_per_sqm.empty?

    avg_price_sqm = prices_per_sqm.sum / prices_per_sqm.size
    estimated_value = (avg_price_sqm * @property.surface).round(-3)

    bulk_estimate = @property.is_copropriete ? (estimated_value * 1.20).round(-3) : nil

    valuation = @property.valuation || @property.build_valuation
    valuation.update(
      estimated_value: estimated_value,
      min_value: (estimated_value * 0.90).round(-3),
      max_value: (estimated_value * 1.10).round(-3),
      bulk_sale_estimate: bulk_estimate,
      comparable_sales: results.first(5),
      methodology: "Basé sur #{results.size} ventes comparables (source : DVF)",
      dvf_raw: { avg_price_sqm: avg_price_sqm.round(0), sample_size: results.size }
    )
    true
  end

  private

  def fetch_comparable_sales
    response = HTTParty.get(
      DVF_API,
      query: {
        code_postal: @property.zipcode,
        type_local: @property.property_type&.capitalize || "Appartement",
        per_page: 50
      }
    )
    return [] unless response.success?

    data = JSON.parse(response.body)
    (data["resultats"] || []).select do |r|
      r["surface_reelle_bati"].to_f > 0 &&
        r["valeur_fonciere"].to_f > 0 &&
        Date.parse(r["date_mutation"]) > 3.years.ago
    end
  rescue => e
    Rails.logger.error("DVF API error: #{e.message}")
    []
  end
end
