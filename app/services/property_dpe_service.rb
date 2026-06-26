# Pont entre l'état d'un bien et le moteur 3CL DpeEngineService (Temps 1).
# Calcule la classe DPE de départ et la classe atteignable selon un ensemble
# de gestes cochés parmi les 7 macro-postes (TravauxMapperService::CANONICAL_CODES).
#
# Spec : docs/MODELE_DPE_3CL.md
#
# ── Discipline d'entrée ────────────────────────────────────────────────
# L'état initial (énergie de chauffage actuelle, isolation par poste,
# ventilation) est passé EN PARAMÈTRE OBLIGATOIRE et JAMAIS inventé.
# Le diagnostic Temps 1.5 a montré que Property ne stocke pas ces données
# de façon fiable ; la source de l'état initial (rétro-déduction /
# extraction / saisie) est une décision produit tranchée plus tard.
#
# ── Ce que ce service NE FAIT PAS ──────────────────────────────────────
# - Aucune lecture de Property ni d'autre modèle ActiveRecord.
# - Aucune modification de DpeEngineService (figé au Temps 1).
# - Aucune UI (jauge, vues, JS) — c'est du back pur.
class PropertyDpeService
  # Les 7 codes canoniques, alignés avec TravauxMapperService::CANONICAL_CODES
  # et Property::TRAVAUX_BOOL_KEYS (diagnostic Temps 1.5 — mapping §8 vérifié).
  GESTES_VALIDES = %w[
    isolation_murs isolation_toiture isolation_plancher_bas
    menuiseries vmc chauffage chauffe_eau
  ].freeze

  # Clés obligatoires de :etat_initial. Si l'une manque, on lève — pas
  # de défaut silencieux qui inventerait l'état d'un bien.
  ETAT_INITIAL_REQUIS = %i[
    energie_chauffage
    isolation_murs isolation_toiture isolation_plancher_bas isolation_menuiseries
    ventilation
  ].freeze

  # Énergie cible par défaut du geste « chauffage » : PAC air/eau.
  # Choix produit Lauze cohérent avec le parcours de décarbonation typique
  # (cf. §5 du doc : la PAC divise la conso par le COP ~3 ET fait chuter
  # le carbone de 0,300 fioul → 0,079 — double effet, 2-3 classes gagnées).
  # Modifiable via :energie_chauffage_cible.
  ENERGIE_CHAUFFAGE_CIBLE_DEFAUT = :pac

  # Seuil de proximité d'une borne de classe (§9 du doc).
  # En-dessous → on lève proche_seuil pour signaler l'instabilité de la
  # classification (un bien à ±5 % d'un seuil doit être traité comme
  # indéterminé entre deux classes).
  PROCHE_SEUIL_PCT = 0.05

  def self.call(**kw) = new(**kw).call

  def initialize(
    surface:,
    annee_construction:,
    zone_climatique:,
    etat_initial:,                                  # OBLIGATOIRE
    gestes: [],
    energie_chauffage_cible: ENERGIE_CHAUFFAGE_CIBLE_DEFAUT,
    # Géométrie optionnelle (passée telle quelle au moteur si fournie ;
    # sinon le moteur applique ses défauts §5ter.a).
    surface_murs: nil, surface_toiture: nil, surface_plancher_bas: nil,
    surface_fenetres: nil, nombre_fenetres: nil
  )
    unless etat_initial.is_a?(Hash)
      raise ArgumentError,
        "etat_initial doit être un Hash décrivant l'énergie de chauffage, " \
        "l'isolation par poste et la ventilation. Le service n'invente pas."
    end

    cles_manquantes = ETAT_INITIAL_REQUIS - etat_initial.keys
    if cles_manquantes.any?
      raise ArgumentError,
        "etat_initial incomplet — clés manquantes : #{cles_manquantes.inspect}. " \
        "Clés requises : #{ETAT_INITIAL_REQUIS.inspect}. Le service n'invente pas."
    end

    gestes_inconnus = gestes.map(&:to_s) - GESTES_VALIDES
    if gestes_inconnus.any?
      raise ArgumentError,
        "gestes inconnus : #{gestes_inconnus.inspect}. Valides : #{GESTES_VALIDES.inspect}."
    end

    @surface = surface
    @annee   = annee_construction
    @zone    = zone_climatique
    @etat_initial  = etat_initial.dup
    @gestes        = gestes.map(&:to_s)
    @energie_cible = energie_chauffage_cible
    @opts_geom = {
      surface_murs: surface_murs, surface_toiture: surface_toiture,
      surface_plancher_bas: surface_plancher_bas, surface_fenetres: surface_fenetres,
      nombre_fenetres: nombre_fenetres
    }.compact
  end

  def call
    avant = appeler_moteur(@etat_initial)
    apres = appeler_moteur(etat_apres)

    idx  = DpeEngineService::ORDRE_CLASSES
    gain = idx.index(avant[:classe_finale]) - idx.index(apres[:classe_finale])

    {
      classe_avant: avant[:classe_finale],
      classe_apres: apres[:classe_finale],
      conso_avant:  { ep_m2: avant[:conso_ep_m2],  co2_m2: avant[:conso_carbone_m2] },
      conso_apres:  { ep_m2: apres[:conso_ep_m2],  co2_m2: apres[:conso_carbone_m2] },
      gain_classes: gain,
      proche_seuil: proche_seuil?(apres),
      detail: {
        etat_initial:    @etat_initial,
        etat_apres:      etat_apres,
        gv_avant:        avant[:_details][:gv],
        gv_apres:        apres[:_details][:gv],
        breakdown_avant: avant[:_details][:gv_breakdown],
        breakdown_apres: apres[:_details][:gv_breakdown]
      }
    }
  end

  private

  # État obtenu après application des gestes cochés sur l'état initial.
  # Mémoïsé pour rester pur (pas d'appels redondants).
  def etat_apres
    @etat_apres ||= @gestes.reduce(@etat_initial.dup) { |etat, geste| appliquer_geste(etat, geste) }
  end

  def appliquer_geste(etat, geste)
    case geste
    when "isolation_murs"         then etat.merge(isolation_murs: :isole)
    when "isolation_toiture"      then etat.merge(isolation_toiture: :isole)
    when "isolation_plancher_bas" then etat.merge(isolation_plancher_bas: :isole)
    when "menuiseries"            then etat.merge(isolation_menuiseries: :isole)
    when "vmc"                    then etat.merge(ventilation: :vmc_double_flux)
    when "chauffage"              then etat.merge(energie_chauffage: @energie_cible)
    when "chauffe_eau"
      # DpeEngineService n'a qu'UNE énergie pour chauffage ET ECS (cf.
      # §5ter.d : ECS_FORFAIT_EF est indexé par energie_chauffage). Un geste
      # « chauffe-eau » seul n'est donc pas modélisable au Temps 2 sans
      # étendre DpeEngineService. Geste sans effet — limite documentée.
      etat
    else etat
    end
  end

  def appeler_moteur(etat)
    DpeEngineService.call(
      surface_habitable:      @surface,
      annee_construction:     @annee,
      zone_climatique:        @zone,
      energie_chauffage:      etat[:energie_chauffage],
      isolation_murs:         etat[:isolation_murs],
      isolation_toiture:      etat[:isolation_toiture],
      isolation_plancher_bas: etat[:isolation_plancher_bas],
      isolation_menuiseries:  etat[:isolation_menuiseries],
      ventilation:            etat[:ventilation],
      inclure_ecs:            true,
      **@opts_geom
    )
  end

  # Vrai si EP ou CO₂ après travaux est à moins de PROCHE_SEUIL_PCT d'une
  # borne de classe (haute ou basse). §9 du doc : un bien dans cette zone
  # doit être considéré indéterminé entre deux classes ; la jauge devra
  # le signaler au Temps 3.
  def proche_seuil?(resultat)
    proche_classe?(resultat[:conso_ep_m2],      DpeEngineService::SEUILS_EP) ||
      proche_classe?(resultat[:conso_carbone_m2], DpeEngineService::SEUILS_CO2)
  end

  def proche_classe?(valeur, seuils)
    bornes = seuils.map(&:first).reject(&:infinite?)
    bornes.any? { |b| ((valeur - b).abs / b) <= PROCHE_SEUIL_PCT }
  end
end
