class DvfEstimationService
  BASE_URL = "https://apidf.cerema.fr/dvf_opendata/geomutations/"

  def initialize(property)
    @property = property
  end

  def call
    response = HTTParty.get(BASE_URL, query: {
      code_insee: "54395",
      date_mutation_min: 3.years.ago.strftime("%Y-%m-%d"),
      nb_resultats: 50
    }, timeout: 10)

    return fallback unless response.success?

    mutations = JSON.parse(response.body)["results"] rescue []
    comparable = mutations.select do |m|
      m["type_local"] == type_local_label &&
      m["surface_reelle_bati"].to_f.between?(
        @property.surface * 0.75, @property.surface * 1.25
      ) &&
      m["valeur_fonciere"].to_f > 0
    end

    return fallback if comparable.empty?

    prix_m2_values = comparable.map { |m|
      m["valeur_fonciere"].to_f / m["surface_reelle_bati"].to_f
    }.sort
    prix_m2 = prix_m2_values[prix_m2_values.size / 2]

    estimated = (prix_m2 * @property.surface).round(-3)

    valuation = @property.valuation || @property.build_valuation
    valuation.update!(
      estimated_value: estimated,
      min_value:       (estimated * 0.90).round(-3),
      max_value:       (estimated * 1.10).round(-3),
      methodology:     "CEREMA DVF — #{comparable.size} mutations comparables",
      dvf_raw:         { prix_m2: prix_m2.round(0), nb_mutations: comparable.size }
    )

    Rails.logger.info("DvfEstimationService: #{estimated} € estimés (#{comparable.size} mutations)")
  rescue => e
    Rails.logger.error("DvfEstimationService failed: #{e.message}")
    fallback
  end

  private

  def type_local_label
    @property.property_type == "maison" ? "Maison" : "Appartement"
  end

  def fallback
    Rails.logger.warn("DvfEstimationService: fallback — aucune donnée CEREMA exploitable")
  end
end
