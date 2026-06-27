# Calcule, en LECTURE SEULE, ce que donneraient les aides si la cible DPE
# était plus ambitieuse — sans toucher à la cible serveur ni au total
# courant. Sert à l'UI à dire "en visant B, vous débloqueriez ~X € de plus".
#
# Retourne :
#   - nil  → rien à proposer (déjà optimal, revenus manquants, ou aucun
#            saut supérieur ne change le total). L'UI ne montre alors AUCUNE
#            invitation — pas de faux espoir.
#   - Hash → { target: "B", delta: 27_500, total: 32_000 }
#            target  : la cible la plus PROCHE qui débloque des aides en plus
#            delta   : aides additionnelles vs la cible courante (en €)
#            total   : total qu'auraient les aides à cette cible
#
# North star : ce service ne fait que LIRE. Aucune persistance, aucune
# mutation de la Property (cf. dpe_target_override d'AidCalculatorService).
class AidProjectionService
  # Du moins ambitieux au plus ambitieux. On itère vers la droite à partir
  # de la cible courante pour trouver le premier saut qui débloque vraiment.
  ORDRE_DPE_ASC = %w[G F E D C B A].freeze

  def self.call(property, current_total:, travaux_actifs: nil, current_target: nil)
    new(property,
        current_total:  current_total,
        travaux_actifs: travaux_actifs,
        current_target: current_target).call
  end

  # current_target: classe DPE qui sert de point de départ à l'itération
  # vers les cibles supérieures. Quand le caller (PropertiesController#show)
  # a calculé la classe atteignable via PropertyDpeMatrixService, il la
  # passe ici pour que la projection parte du *réel* (matrice) et pas du
  # forfait DB. Absent → fallback historique sur @property.dpe_target,
  # ce qui garde le service compatible avec ses callers existants et avec
  # ses tests unitaires (aucune cassure pour qui n'a pas la matrice).
  def initialize(property, current_total:, travaux_actifs: nil, current_target: nil)
    @property        = property
    @current_total   = current_total.to_i
    @travaux_actifs  = travaux_actifs
    @current_target  = current_target&.to_s&.upcase
  end

  def call
    current = @current_target.presence || @property.dpe_target&.upcase
    return nil if current.blank?

    idx = ORDRE_DPE_ASC.index(current)
    return nil if idx.nil?
    return nil if idx == ORDRE_DPE_ASC.size - 1   # déjà A → rien au-dessus

    ORDRE_DPE_ASC[(idx + 1)..].each do |candidate|
      projected = AidCalculatorService.new(
        @property,
        travaux_actifs:      @travaux_actifs,
        dpe_target_override: candidate
      ).call

      delta = projected[:total_subventions].to_i - @current_total
      next if delta <= 0

      return {
        target: candidate,
        delta:  delta,
        total:  projected[:total_subventions].to_i
      }
    end

    nil
  end
end
