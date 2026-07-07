# Détermine, à partir des FAITS techniques d'un bien, la liste canonique
# des gestes de rénovation ACTIONNABLES par son propriétaire.
#
# ── Pourquoi côté serveur ─────────────────────────────────────────────
# Historiquement, la liste des cases à cocher sur la fiche bien sortait
# de la narration LLM (analysis.content["energie"]["travaux"]). Cette
# narration est non déterministe : deux runs sur le même PDF pouvaient
# donner deux listes de gestes différentes — cf. écart biens 232/233
# (diagnostic 07/07), où un run proposait un « remplacement de la
# chaudière collective à 3 500 € » là où l'autre l'ignorait.
#
# On INVERSE la dépendance : la liste des gestes proposables vient
# désormais des faits du bien (property_type, is_copropriete, énergie
# de chauffage, mode collectif/individuel, position du lot). La
# narration LLM ne sert plus qu'à ENRICHIR (libellés spécifiques,
# fourchettes de coûts) les gestes que ce service retient — pas à en
# définir la liste.
#
# ── Règles d'exclusion (minimales) ────────────────────────────────────
# Point de départ : TravauxMapperService::CANONICAL_CODES (7 codes).
# On exclut :
#
#   - « chauffage » : si le lot est en copropriété avec chauffage
#     collectif. Le propriétaire seul ne peut pas remplacer la
#     chaudière commune (vote AG requis). La mobilisation en AG figure
#     dans « Autres pistes » de la fiche bien, pas dans les cases à
#     cocher qui pilotent la matrice DPE et le budget travaux.
#
#   - « isolation_toiture » : pour un appartement en RDC ou étage
#     intermédiaire — la paroi haute est adjacente à un autre lot
#     chauffé, pas à l'extérieur.
#
#   - « isolation_plancher_bas » : pour un appartement en dernier étage
#     ou étage intermédiaire — la dalle est adjacente à un autre lot
#     chauffé, pas à un vide sanitaire / cave.
#
# ── Comportement conservateur en cas d'incertitude ────────────────────
# Si position_lot est absent ou :inconnu, on N'EXCLUT PAS toiture ni
# plancher bas — on préfère laisser une case cochable qui ne servira
# pas plutôt que priver l'utilisateur d'un geste qu'il pourrait avoir.
# La correction fine (déperdition physique nulle sur les parois
# adjacentes à un lot chauffé) est portée par le moteur DpeEngineService
# via des coefficients b (cf. commit 3).
class ProposableGestesService
  # Positions du lot qui excluent le geste « isolation_toiture ».
  # Un appartement en dernier étage a une vraie toiture ; les autres
  # ont une dalle au-dessus qui donne sur un lot chauffé.
  TOITURE_EXCLUE_SI_POSITION = %w[rdc etage_intermediaire].freeze

  # Positions du lot qui excluent le geste « isolation_plancher_bas ».
  # Un RDC a une vraie dalle sur vide sanitaire ; les autres ont un
  # plancher qui donne sur un lot chauffé.
  PLANCHER_EXCLU_SI_POSITION = %w[dernier_etage etage_intermediaire].freeze

  def self.call(property) = new(property).call

  def initialize(property)
    @property = property
  end

  def call
    codes = TravauxMapperService::CANONICAL_CODES.dup
    codes.delete("chauffage")              if chauffage_hors_perimetre?
    codes.delete("isolation_toiture")      if toiture_hors_perimetre?
    codes.delete("isolation_plancher_bas") if plancher_hors_perimetre?
    codes
  end

  private

  def chauffage_hors_perimetre?
    @property.chauffage_collectif?
  end

  def toiture_hors_perimetre?
    return false unless @property.kind_appartement?
    TOITURE_EXCLUE_SI_POSITION.include?(position_lot_courante)
  end

  def plancher_hors_perimetre?
    return false unless @property.kind_appartement?
    PLANCHER_EXCLU_SI_POSITION.include?(position_lot_courante)
  end

  # Lecture défensive de position_lot : la colonne est ajoutée dans le
  # commit 2 de la même série. Tant qu'elle n'existe pas, on renvoie
  # nil → comportement conservateur (toiture et plancher restent
  # proposables sur les appartements).
  def position_lot_courante
    @property.try(:position_lot).to_s
  end
end
