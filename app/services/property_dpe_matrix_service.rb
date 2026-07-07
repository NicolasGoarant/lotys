# Pré-calcul serveur des 128 combinaisons de gestes pour un bien donné.
# Future source de vérité unique de la jauge (consommation au Temps 3b-2).
# Cette session produit la table et l'expose, sans débrancher DPE_IMPACT.
#
# ── Pourquoi ──
# La jauge consomme aujourd'hui un forfait JS (DPE_IMPACT) dupliqué entre
# Ruby et JS, et déconnecté du moteur thermique. PropertyDpeMatrixService
# enumère les 128 = 2^7 sous-ensembles des 7 gestes canoniques et appelle
# PropertyDpeService pour chacun : la table résultante est la projection
# complète du moteur 3CL sur l'espace des choix utilisateur, calculée une
# fois au render et lue ensuite côté JS sans réseau (option C du diag 3b).
#
# ── Périmètre ──
# Service en LECTURE de Property. Ne modifie aucune colonne. Ne modifie pas
# le moteur ni PropertyDpeService.
class PropertyDpeMatrixService
  # Ensemble canonique des 7 gestes. C'est la BORNE SUPÉRIEURE de la
  # matrice, pas nécessairement les gestes énumérés pour un bien donné —
  # cf. #gestes_proposables ci-dessous qui restreint selon les faits du
  # bien (chauffage collectif, appartement mitoyen, etc.).
  GESTES = %w[
    isolation_murs isolation_toiture isolation_plancher_bas
    menuiseries vmc chauffage chauffe_eau
  ].freeze

  # Énergie de repli quand Property#energie_chauffage = "inconnue" : on doit
  # quand même faire tourner le moteur (qui refuse :inconnue). On retient
  # :gaz (énergie médiane du parc), et on lève etat_incertain pour signaler
  # honnêtement que la matrice est calculée sur une hypothèse, pas un fait.
  ENERGIE_PAR_DEFAUT_SI_INCONNUE = :gaz

  # Mapping zipcode (2 premiers chiffres = département) → zone climatique
  # RT/3CL. Liste simplifiée : H2 (Ouest/Centre) et H3 (Sud-Méditerranée) ;
  # tout le reste = H1. Dupliqué temporairement avec tmp/validate_dpe_engine.rb
  # — à factoriser dans un service dédié dès qu'on en aura 3+ consommateurs.
  DEPT_H3 = %w[11 13 30 34 66 83 84].freeze
  DEPT_H2 = %w[16 17 22 24 29 33 35 36 37 40 44 46 47 49 50 53 56 61 62 64
               65 79 85 86 87].freeze

  def self.call(property) = new(property).call

  def initialize(property)
    @property = property
  end

  def call
    etat_observe = reconstruire_etat_initial
    etat_pour_moteur = etat_observe.merge(energie_chauffage: energie_pour_moteur(etat_observe))
    {
      etat_initial:          etat_observe,
      etat_incertain:        etat_incertain?,
      details_incertitude:   details_incertitude(etat_observe),
      combinaisons:          calculer_combinaisons(etat_pour_moteur),
      priorite_gestes:       classer_priorite_gestes(etat_pour_moteur),
      meta: {
        surface:           @property.surface,
        annee:             @property.construction_year,
        property_type:     @property.property_type,
        zone_climatique:   zone_climatique,
        dpe_actuel_db:     @property.dpe_class,
        gestes_proposables: gestes_proposables
      }
    }
  end

  # Liste des gestes réellement énumérés dans la matrice pour CE bien.
  # Source unique de vérité serveur : la vue et la matrice consomment
  # la même liste, plus de dérive possible entre availableCodes (DOM)
  # et l'espace des combinaisons calculé côté back.
  def gestes_proposables
    @gestes_proposables ||= ProposableGestesService.call(@property)
  end

  private

  # ── État initial reconstitué depuis Property ──────────────────────────
  # Énergie : on lit Property#energie_chauffage typé (Temps 3b 5 énergies + :inconnue).
  # Isolation : grille §3bis (faute de capture isolation typée — dette (b)).
  # Plancher bas : :non_isole par défaut (le moteur applique alors §3 Upb=0,45
  # « entrevous isolant », valeur conservatrice par défaut).
  # Ventilation : :aucune_vmc par défaut (la VMC actuelle n'est pas captée).
  def reconstruire_etat_initial
    iso = InsulationDecadeGrid.call(@property.construction_year,
                                    property_type: @property.property_type)
    {
      energie_chauffage:      @property.energie_chauffage.to_s.to_sym,
      isolation_murs:         iso[:murs],
      isolation_toiture:      iso[:toiture],
      isolation_plancher_bas: :non_isole,
      isolation_menuiseries:  iso[:menuiseries],
      ventilation:            :aucune_vmc
    }
  end

  # Énergie qui sera réellement passée au moteur. Identique à etat_observe
  # sauf quand l'énergie observée est :inconnue — auquel cas on substitue
  # ENERGIE_PAR_DEFAUT_SI_INCONNUE. La substitution est traçable via
  # etat_incertain + details_incertitude.
  def energie_pour_moteur(etat)
    etat[:energie_chauffage] == :inconnue ? ENERGIE_PAR_DEFAUT_SI_INCONNUE
                                          : etat[:energie_chauffage]
  end

  # Vrai dès qu'au moins une dimension de l'état initial est :deduit ou
  # :inconnue. Aujourd'hui l'isolation vient toujours de la grille (:deduit
  # par essence), donc l'état est intrinsèquement incertain tant que la
  # capture d'isolation n'est pas implémentée (dette (b)).
  def etat_incertain?
    true
  end

  def details_incertitude(etat)
    {
      energie_valeur:    etat[:energie_chauffage].to_s,
      energie_source:    (@property.energie_chauffage_source || "inconnue").to_s,
      energie_utilisee_pour_calcul: energie_pour_moteur(etat).to_s,
      isolation_source:  "deduit",
      isolation_origine: "InsulationDecadeGrid§3bis(construction_year=#{@property.construction_year})",
      ventilation_source: "deduit",
      ventilation_valeur: etat[:ventilation].to_s
    }
  end

  # ── 2^N combinaisons sur les gestes PROPOSABLES pour ce bien ──────────
  # N = gestes_proposables.size ≤ 7. Pour une maison hors copro tout est
  # proposable → 128 comme avant. Pour un appartement en copro gaz
  # collectif à étage intermédiaire, N = 4 (chauffage, toiture et
  # plancher exclus) → 16 combinaisons — matrice cohérente avec les
  # cases à cocher que la vue affiche réellement.
  # Hash { "<clé triée>" → {classe, ep, co2, proche_seuil} }
  def calculer_combinaisons(etat)
    gestes = gestes_proposables
    nb_combi = 2**gestes.size
    (0...nb_combi).each_with_object({}) do |i, h|
      gestes_actifs = gestes.each_with_index.filter_map { |g, idx| g if i[idx] == 1 }
      cle = gestes_actifs.sort.join(",")
      h[cle] = appeler_pds(etat, gestes_actifs)
    end
  end

  # ── Priorité spécifique au bien : gain EP de chaque geste pris seul ──
  # Trié décroissant. Remplacera l'ordre forfaitaire DPE_IMPACT (qui est
  # le même pour tous les biens) au Temps 3b-2. On classe uniquement les
  # gestes proposables pour ce bien (les autres ne servent à rien).
  def classer_priorite_gestes(etat)
    base = appeler_pds(etat, [])
    gestes_proposables.map do |geste|
      r = appeler_pds(etat, [geste])
      {
        code:         geste,
        gain_ep:      (base[:ep_m2] - r[:ep_m2]).round(2),
        gain_co2:     (base[:co2_m2] - r[:co2_m2]).round(2),
        classe_seul:  r[:classe]
      }
    end.sort_by { |i| -i[:gain_ep] }
  end

  def appeler_pds(etat, gestes)
    pds = PropertyDpeService.call(
      surface:            @property.surface,
      annee_construction: @property.construction_year,
      zone_climatique:    zone_climatique,
      etat_initial:       etat,
      gestes:             gestes
    )
    {
      classe:       pds[:classe_apres],
      ep_m2:        pds[:conso_apres][:ep_m2],
      co2_m2:       pds[:conso_apres][:co2_m2],
      proche_seuil: pds[:proche_seuil]
    }
  end

  def zone_climatique
    dept = @property.zipcode.to_s[0, 2]
    return :h3 if DEPT_H3.include?(dept)
    return :h2 if DEPT_H2.include?(dept)
    :h1
  end
end
