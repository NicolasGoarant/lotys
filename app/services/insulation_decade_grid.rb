# Grille de rétro-déduction de l'état d'isolation par période de construction.
# Spec : docs/MODELE_DPE_3CL.md §3bis (sourcée Ubât typique Choisir.com,
# dates de RT depuis Wikipédia + arrêtés ministériels).
#
# SOURCE DE VÉRITÉ UNIQUE. Tout consommateur DOIT lire cette table :
#   - tmp/validate_dpe_engine.rb (validation sur biens réels)
#   - futur PropertyDpeService quand on câblera la rétro-déduction en prod
#   - futurs prompts d'extraction (pour ne pas demander à Claude ce que
#     l'année permet déjà de déduire)
# Pas de copie locale, jamais.
#
# Statut : repli de DERNIER RECOURS, source :deduit. N'écrase jamais une
# donnée réelle ; cf. merge_with_extracted ci-dessous.
#
# ── Choix sur l'état :partiel ─────────────────────────────────────────
# Le moteur DpeEngineService ne connaît aujourd'hui que :isole et :non_isole.
# Cette grille renvoie quand même :partiel pour la zone grise 1983-2000,
# parce que c'est la réalité physique observée (cf. ID 71, 5 cm d'isolation
# intérieure, Umur ≈ 1,5 ; cf. §3bis).
#
# DETTE EXPLICITE : le moteur devra apprendre :partiel à la session
# suivante (calage Umur_partiel ≈ 1,0–1,5, hypothèse Lauze §3bis). En
# attendant, les consommateurs choisissent une traduction (par exemple
# :partiel → :isole pour rapprocher les bâtis 1990-2000 du DPE réel, ou
# :partiel → :non_isole pour la convention conservatrice). Voir le
# script tmp/validate_dpe_engine.rb pour la traduction retenue
# temporairement et son impact mesuré sur ID 69.
class InsulationDecadeGrid
  # Chaque entrée : [borne_haute_inclusive, murs, toiture, menuiseries].
  # Bornes inclusives à droite, parcourues dans l'ordre.
  GRILLE = [
    [1973,             :non_isole, :non_isole, :non_isole],  # avant 1974, aucune RT
    [1982,             :non_isole, :non_isole, :non_isole],  # RT 1974
    [1989,             :partiel,   :partiel,   :non_isole],  # RT 1982/1988 (vitrage simple dominant)
    [2000,             :partiel,   :partiel,   :partiel],    # RT 1988/2000 (double émergent)
    [2006,             :isole,     :isole,     :isole],      # RT 2000 (isolation systématisée)
    [2012,             :isole,     :isole,     :isole],      # RT 2005
    [Float::INFINITY,  :isole,     :isole,     :isole]       # RT 2012 / RE 2020
  ].freeze

  # État d'isolation déduit de l'année de construction.
  # property_type accepté pour stabilité d'API (extension future :
  # appartement intermédiaire = moins de parois extérieures), non utilisé
  # à ce stade.
  # Retourne { murs:, toiture:, menuiseries: } parmi {:non_isole, :partiel, :isole}.
  # year nil → repli conservateur :non_isole partout (pas d'invention).
  def self.call(construction_year, property_type: nil)
    return etat_conservateur if construction_year.nil?

    _borne, m, t, w = GRILLE.find { |borne, *| construction_year <= borne }
    { murs: m, toiture: t, menuiseries: w }
  end

  # Combine un état extrait (source plus fiable) avec la grille (source :deduit).
  # extracted = { murs: :isole, toiture: nil, menuiseries: :non_isole }
  # Les valeurs non-nil de extracted priment ; les valeurs nil ou absentes
  # sont complétées par la grille. Garantit qu'une donnée extraite n'est
  # JAMAIS écrasée par le repli, même si la grille « pense mieux ».
  def self.merge_with_extracted(construction_year, extracted: {})
    call(construction_year).merge(extracted.compact)
  end

  def self.etat_conservateur
    { murs: :non_isole, toiture: :non_isole, menuiseries: :non_isole }
  end
end
