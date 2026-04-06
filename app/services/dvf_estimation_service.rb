require 'csv'
require 'open-uri'
require 'zlib'

class DvfEstimationService
  DVF_URL = "https://files.data.gouv.fr/geo-dvf/latest/csv/2023/departements/54.csv.gz"
  CODE_INSEE = "54395"

  def initialize(property)
    @property = property
  end

  def call
    mutations = load_mutations
    return fallback("CSV vide ou inaccessible") if mutations.empty?

    type = @property.property_type == "maison" ? "Maison" : "Appartement"

    comparable = mutations.select do |m|
      m[:code_commune] == CODE_INSEE &&
      m[:type_local] == type &&
      m[:surface].between?(@property.surface * 0.75, @property.surface * 1.25) &&
      m[:valeur] > 0
    end

    return fallback("Aucune mutation comparable (#{type}, ~#{@property.surface}m², Nancy)") if comparable.empty?

    prix_m2_list = comparable.map { |m| m[:valeur] / m[:surface] }.sort
    prix_m2 = prix_m2_list[prix_m2_list.size / 2]

    estimated = (prix_m2 * @property.surface).round(-3)

    valuation = @property.valuation || @property.build_valuation
    valuation.update!(
      estimated_value: estimated,
      min_value:       (estimated * 0.90).round(-3),
      max_value:       (estimated * 1.10).round(-3),
      methodology:     "DVF data.gouv 2023 — #{comparable.size} mutations comparables (#{type}, Nancy)",
      dvf_raw:         { prix_m2: prix_m2.round(0), nb_mutations: comparable.size }
    )

    Rails.logger.info("DvfEstimationService: #{estimated}€ (#{comparable.size} mutations, prix/m² médian: #{prix_m2.round(0)}€)")
  rescue => e
    Rails.logger.error("DvfEstimationService failed: #{e.message}")
    fallback(e.message)
  end

  private

  def load_mutations
    mutations = []
    Zlib::GzipReader.open(download_csv) do |gz|
      CSV.new(gz, headers: true).each do |row|
        next if row["valeur_fonciere"].blank? || row["surface_reelle_bati"].blank?
        next if row["type_local"].blank?
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

  def download_csv
    tmp = Tempfile.new(["dvf54", ".csv.gz"])
    tmp.binmode
    URI.open(DVF_URL) { |f| tmp.write(f.read) }
    tmp.rewind
    tmp.path
  end

  def fallback(reason)
    Rails.logger.warn("DvfEstimationService fallback: #{reason}")
  end
end
