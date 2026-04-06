require 'csv'
require 'open-uri'
require 'zlib'

class DvfEstimationService
  DVF_URL      = "https://files.data.gouv.fr/geo-dvf/latest/csv/2023/departements/54.csv.gz"
  CACHE_PATH   = Rails.root.join("tmp", "dvf54_cache.csv.gz")
  CACHE_MAX_AGE = 7.days

  def initialize(property)
    @property = property
  end

  def call
    mutations = load_mutations
    return fallback("CSV vide ou inaccessible") if mutations.empty?

    type = @property.property_type == "maison" ? "Maison" : "Appartement"

    comparable = mutations.select do |m|
      m[:code_commune] == "54395" &&
      m[:type_local]   == type &&
      m[:surface].between?(@property.surface * 0.75, @property.surface * 1.25) &&
      m[:valeur] > 0
    end

    return fallback("Aucune mutation comparable (#{type}, ~#{@property.surface}m², Nancy)") if comparable.empty?

    prix_m2_list = comparable.map { |m| m[:valeur] / m[:surface] }.sort
    prix_m2      = prix_m2_list[prix_m2_list.size / 2]
    estimated    = (prix_m2 * @property.surface).round(-3)

    valuation = @property.valuation || @property.build_valuation
    valuation.update!(
      estimated_value: estimated,
      min_value:       (estimated * 0.90).round(-3),
      max_value:       (estimated * 1.10).round(-3),
      methodology:     "DVF data.gouv 2023 — #{comparable.size} mutations comparables (#{type}, Nancy)",
      dvf_raw:         { prix_m2: prix_m2.round(0), nb_mutations: comparable.size }
    )

    Rails.logger.info("DvfEstimationService: #{estimated}€ — #{comparable.size} mutations, #{prix_m2.round(0)}€/m²")
  rescue => e
    Rails.logger.error("DvfEstimationService failed: #{e.message}")
    fallback(e.message)
  end

  private

  def load_mutations
    ensure_cache
    mutations = []
    Zlib::GzipReader.open(CACHE_PATH.to_s) do |gz|
      CSV.new(gz, headers: true).each do |row|
        next if row["valeur_fonciere"].blank? || row["surface_reelle_bati"].blank?
        next unless %w[Appartement Maison].include?(row["type_local"])
        mutations << {
          code_commune: row["code_commune"],
          type_local:   row["type_local"],
          valeur:       row["valeur_fonciere"].to_f,
          surface:      row["surface_reelle_bati"].to_f
        }
      end
    end
    mutations
  rescue => e
    Rails.logger.error("DvfEstimationService#load_mutations: #{e.message}")
    []
  end

  def ensure_cache
    if !File.exist?(CACHE_PATH) || File.mtime(CACHE_PATH) < Time.now - CACHE_MAX_AGE
      Rails.logger.info("DvfEstimationService: téléchargement CSV DVF 54...")
      URI.open(DVF_URL, read_timeout: 30) do |f|
        File.binwrite(CACHE_PATH, f.read)
      end
      Rails.logger.info("DvfEstimationService: CSV mis en cache (#{File.size(CACHE_PATH) / 1024}Ko)")
    else
      age = ((Time.now - File.mtime(CACHE_PATH)) / 86400).round(1)
      Rails.logger.info("DvfEstimationService: cache utilisé (#{age}j)")
    end
  end

  def fallback(reason)
    Rails.logger.warn("DvfEstimationService fallback: #{reason}")
  end
end
