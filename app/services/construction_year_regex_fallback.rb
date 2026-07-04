# Filet déterministe : retrouve l'année de construction dans le texte
# concaténé des documents quand l'extraction LLM a échoué (champ nil).
#
# Règle d'or : en cas de doute, retourne nil — JAMAIS d'approximation.
# Une mauvaise année fausse la matrice de projection DPE et supprime le
# bandeau d'invite qui permettrait au propriétaire de corriger.
#
# Miroir de SurfaceRegexFallback (même stratégie : contextes ancrés,
# tolérance de désaccord, bornes de sécurité, tally sur les hits).
class ConstructionYearRegexFallback
  # Trois patterns, du plus contextualisé au moins. Chacun exige un
  # contexte ancré ("année de construction", "date de construction",
  # "construit(e) en") pour éviter de capturer un millésime de facture,
  # une date d'acte notarié, une année de loi ("Loi Carrez 1996").
  #
  # NB fenêtre : [^0-9]{0,40} borne le trou entre le contexte et le
  # nombre à 40 caractères non-digit. On AUTORISE les sauts de ligne
  # dans cette fenêtre : même avec `pdftotext -layout`, certains DPE
  # restituent le libellé et la valeur sur des lignes différentes
  # (parfois une ligne vide entre les deux). Une fenêtre de 40 couvre
  # ce cas sans laisser passer une année située un paragraphe plus
  # loin — cf. test "NC + Facture 2026" qui reste à ~42 chars du
  # libellé (nil).
  ANNEE_CONSTRUCTION_RE = /ann[eé]e\s+de\s+construction[^0-9]{0,40}(\d{4})\b/i
  DATE_CONSTRUCTION_RE  = /date\s+de\s+construction[^0-9]{0,40}(\d{4})\b/i
  # Pour "construit(e) en <année>", pas de fenêtre : \s+ après "en"
  # accepte espace ou saut de ligne, mais on veut la juxtaposition
  # immédiate — sinon on capturerait "construit en dur, rénové en 2010".
  CONSTRUIT_EN_RE       = /construit(?:e)?\s+en\s+(\d{4})\b/i

  PATTERNS = {
    annee_construction: ANNEE_CONSTRUCTION_RE,
    date_construction:  DATE_CONSTRUCTION_RE,
    construit_en:       CONSTRUIT_EN_RE
  }.freeze

  # Borne basse : très peu de bâti d'habitation avant 1700 (au-delà on
  # est en monument historique, hors périmètre de la plateforme).
  # Borne haute : année courante + 2 (permis de construire en cours de
  # réalisation, VEFA à livrer).
  MIN_YEAR = 1700

  # Si plusieurs matches divergent de plus de 2 ans, on refuse de
  # trancher — un DPE et un titre de propriété doivent s'accorder.
  AGREEMENT_TOLERANCE = 2

  def self.call(text)
    new(text).call
  end

  def initialize(text)
    @text = text.to_s
  end

  def call
    return nil if @text.blank?

    max_year = Date.current.year + 2
    hits     = []

    PATTERNS.each do |label, regex|
      @text.scan(regex).each do |captures|
        value = captures.first.to_i
        next unless value >= MIN_YEAR && value <= max_year
        hits << [value, label]
      end
    end

    return nil if hits.empty?

    values = hits.map(&:first)
    spread = values.max - values.min
    if spread > AGREEMENT_TOLERANCE
      Rails.logger.info("ConstructionYearRegexFallback: désaccord (#{values.uniq.sort.join(', ')}) → nil pour ne pas deviner")
      return nil
    end

    best    = values.tally.max_by { |_v, n| n }.first
    sources = hits.select { |v, _| v == best }.map(&:last).uniq
    Rails.logger.info("ConstructionYearRegexFallback: #{best} retenu (matches=#{hits.size}, sources=#{sources.join(',')})")
    best
  end
end
