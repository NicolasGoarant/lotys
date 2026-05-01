require 'csv'
require 'open-uri'
require 'zlib'

class DvfEstimationService
  DVF_URL      = "https://files.data.gouv.fr/geo-dvf/latest/csv/2023/departements/54.csv.gz"
  S3_CACHE_KEY = "cache/dvf54.csv.gz"
  CACHE_MAX_AGE = 7.days
  LOCAL_CACHE  = Rails.root.join("tmp", "dvf54_cache.csv.gz")

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
    Zlib::GzipReader.open(LOCAL_CACHE.to_s) do |gz|
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
    if s3_available?
      ensure_cache_s3
    else
      ensure_cache_local
    end
  end

  def ensure_cache_s3
    s3 = Aws::S3::Client.new(
      region:            ENV.fetch("AWS_REGION", "eu-west-3"),
      access_key_id:     ENV["AWS_ACCESS_KEY_ID"],
      secret_access_key: ENV["AWS_SECRET_ACCESS_KEY"]
    )
    bucket = ENV.fetch("S3_BUCKET", "lauze-documents")

    # Vérifier l'âge du cache S3
    begin
      head = s3.head_object(bucket: bucket, key: S3_CACHE_KEY)
      age  = Time.now - head.last_modified
      if age < CACHE_MAX_AGE
        Rails.logger.info("DvfEstimationService: cache S3 utilisé (#{(age / 86400).round(1)}j)")
        s3.get_object(bucket: bucket, key: S3_CACHE_KEY, response_target: LOCAL_CACHE.to_s)
        return
      end
    rescue Aws::S3::Errors::NotFound
      Rails.logger.info("DvfEstimationService: pas de cache S3, téléchargement...")
    end

    # Télécharger et uploader sur S3
    download_dvf
    s3.put_object(bucket: bucket, key: S3_CACHE_KEY, body: File.binread(LOCAL_CACHE.to_s))
    Rails.logger.info("DvfEstimationService: CSV uploadé sur S3 (#{File.size(LOCAL_CACHE) / 1024}Ko)")
  end

  def ensure_cache_local
    if !File.exist?(LOCAL_CACHE) || File.mtime(LOCAL_CACHE) < Time.now - CACHE_MAX_AGE
      download_dvf
    else
      age = ((Time.now - File.mtime(LOCAL_CACHE)) / 86400).round(1)
      Rails.logger.info("DvfEstimationService: cache local utilisé (#{age}j)")
    end
  end

  def download_dvf
    Rails.logger.info("DvfEstimationService: téléchargement CSV DVF 54...")
    URI.open(DVF_URL, read_timeout: 30) do |f|
      File.binwrite(LOCAL_CACHE.to_s, f.read)
    end
    Rails.logger.info("DvfEstimationService: CSV téléchargé (#{File.size(LOCAL_CACHE) / 1024}Ko)")
  end

  def s3_available?
    ENV["AWS_ACCESS_KEY_ID"].present? && ENV["S3_BUCKET"].present?
  end

  def fallback(reason)
    Rails.logger.warn("DvfEstimationService fallback: #{reason}")
  end
end
