# Filet déterministe : retrouve la surface habitable dans le texte concaténé
# des documents quand l'extraction LLM a échoué (champ resté nil).
#
# Règle d'or : en cas de doute, retourne nil — JAMAIS d'approximation.
# Un mauvais chiffre supprime le bandeau "analyse incomplète" et empêche
# le propriétaire de corriger, alors qu'un nil le préserve.
class SurfaceRegexFallback
  # Trois patterns, du plus contextualisé au moins. Chacun exige un mot
  # de contexte ("surface habitable", "Carrez/Boutin", "type de logement")
  # pour éviter de capturer "410 kWh/m²", "7 m².K/W", "120 m² de toiture".
  SURFACE_HABITABLE_RE = /surface\s+habitable[^0-9]{0,40}(\d{2,3})\s*m[²2](?![.\w])/i
  CARREZ_BOUTIN_RE     = /(?:loi\s+)?(?:carrez|boutin)[^0-9]{0,40}(\d{2,3})\s*m[²2](?![.\w])/i
  TYPE_LOGEMENT_RE     = /type\s+de\s+(?:logement|bien)[^:\n]{0,15}:\s*[^—\n]{1,80}—\s*(\d{2,3})\s*m[²2](?![.\w])/i

  PATTERNS = {
    surface_habitable: SURFACE_HABITABLE_RE,
    carrez_boutin:     CARREZ_BOUTIN_RE,
    type_logement:     TYPE_LOGEMENT_RE
  }.freeze

  # Borne basse : studio Loi Carrez minimum ≈ 9 m². Borne haute : 1000 m²
  # couvre tout ce qui n'est pas un château — au-delà c'est forcément du
  # parasite (surface terrain, surface chantier, etc.).
  MIN_SURFACE = 9
  MAX_SURFACE = 1000

  # Si plusieurs matches divergent de plus de 2 m², on refuse de trancher.
  AGREEMENT_TOLERANCE = 2

  def self.call(text)
    new(text).call
  end

  def initialize(text)
    @text = text.to_s
  end

  def call
    return nil if @text.blank?

    hits = []
    PATTERNS.each do |label, regex|
      @text.scan(regex).each do |captures|
        value = captures.first.to_i
        next unless value >= MIN_SURFACE && value <= MAX_SURFACE
        hits << [value, label]
      end
    end

    return nil if hits.empty?

    values = hits.map(&:first)
    spread = values.max - values.min
    if spread > AGREEMENT_TOLERANCE
      Rails.logger.info("SurfaceRegexFallback: désaccord (#{values.uniq.sort.join(', ')}) → nil pour ne pas deviner")
      return nil
    end

    best    = values.tally.max_by { |_v, n| n }.first
    sources = hits.select { |v, _| v == best }.map(&:last).uniq
    Rails.logger.info("SurfaceRegexFallback: #{best} m² retenus (matches=#{hits.size}, sources=#{sources.join(',')})")
    best
  end
end
