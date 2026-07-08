# Moteur DPE 3CL-inspiré (voie absolue §5bis du doc).
# Spec : docs/MODELE_DPE_3CL.md (à déplacer depuis app/assets après validation).
# Statut : 3CL-inspiré, non opposable. Limites assumées : voir §9 du doc.
#
# Chaîne de calcul (§5bis) :
#   GV (W/K) → × DH14 × coef_apports → Bch (kWh) → ÷ (Rg × Rerd) → conso finale
#     → × FacteurEP → kWhEP/m² → classe énergie (§2)
#     × FacteurCO₂ → kgCO₂/m² → classe carbone (§2)
#   Classe finale = pire(énergie, carbone).
class DpeEngineService
  # ── §3 — U₀ non isolé (W/m².K), notice ADEME 08/10/2021 ────────────────
  UMUR_NON_ISOLE      = 2.5
  UPH_NON_ISOLE       = 2.5
  UPB_DEFAUT          = 0.45
  UW_SIMPLE_VITRAGE   = 5.8
  UMUR_PLAFOND_CALCUL = 2.0  # Min(Umur ; 2) appliqué aux calculs 3CL (§3)

  # ── §3bis — état :partiel (zone grise 1983-2000, RT 1982/1988/2000) ────
  # Bâtis avec amorce d'isolation mais sous les standards RT 2000+.
  # Calage FIGÉ (cf. §3bis du doc, Temps 3a quater) :
  UMUR_PARTIEL = 1.5    # Ancré sur ID 71 : 5 cm laine intérieure + parpaing
                        # 20 cm + Rsi+Rse (0,17) → R total ≈ 0,67 → U ≈ 1,5.
                        # Valeur OBSERVÉE, pas calibrée sur l'oracle.
                        # Conservative : 1,5 < UMUR_PLAFOND_CALCUL (2,0) donc
                        # le plafond §3 ne s'applique pas — c'est volontaire.
  UPH_PARTIEL  = 0.59   # Milieu géométrique entre UPH_NON_ISOLE (2,5) et
                        # Uph_isolé (≈0,140 : R=7+0,17) : √(2,5 × 0,140) ≈ 0,591.
                        # Hypothèse Lauze, à affiner si ancrage observé.
  UW_PARTIEL   = 2.75   # Milieu géométrique entre UW_SIMPLE_VITRAGE (5,8) et
                        # UW_DOUBLE_VITRAGE (1,3) : √(5,8 × 1,3) ≈ 2,747.
                        # Cohérent avec « double émergent » années 90 (Uw 2,5-3,0).
                        # Hypothèse Lauze, à affiner.
  UPB_PARTIEL  = 0.38   # Milieu géométrique entre UPB_DEFAUT (0,45) et
                        # Upb_isolé (≈0,316 : R=3+0,17) : √(0,45 × 0,316) ≈ 0,377.
                        # Note : écart partiel ↔ isolé minime sur ce poste,
                        # le §3 prend déjà 0,45 « entrevous isolant » comme défaut.
                        # Hypothèse Lauze, à affiner.

  # ── §4 — R minimums réglementaires rénovation (MaPrimeRénov / CEE) ──────
  R_ITI_MIN            = 3.7
  R_COMBLES_PERDUS_MIN = 7.0
  R_PLANCHER_BAS_MIN   = 3.0
  UW_DOUBLE_VITRAGE    = 1.3

  # R_paroi résiduelle = Rsi + Rse = 0,13 + 0,04 = 0,17 m².K/W
  # pour paroi verticale (norme NF EN ISO 6946, résistances superficielles
  # d'échange). Valeur de manuel thermique, constante physique — pas un
  # coefficient de calibrage. Le §4 du doc cite 0,3–0,5 qui inclut en plus
  # la résistance de la paroi existante (parpaing/brique) ; on s'en tient
  # ici aux résistances superficielles pures (légèrement conservatif sur
  # le U après isolation : 0,258 au lieu de 0,238 pour R_isolant = 3,7).
  R_RESIDUELLE_PAROI = 0.17

  # ── §1 — coefficients de réduction des déperditions b ──────────────────
  # Comportement de base (maison ou appartement de position inconnue) :
  #   B_EXTERIEUR    = 1.0  toit sur extérieur / murs / fenêtres
  #   B_PLANCHER_BAS = 0.8  dalle sur vide sanitaire / cave non chauffés
  # Ces coefficients restent LA source de vérité tant qu'aucune info de
  # mitoyenneté ne les remplace (cf. b_toiture / b_plancher_bas ci-dessous).
  B_EXTERIEUR    = 1.0
  B_PLANCHER_BAS = 0.8   # sur vide sanitaire / cave / garage non chauffé

  # ── Mitoyenneté verticale (appartements) ─────────────────────────────
  # Un appartement mitoyen d'un lot chauffé au-dessus n'a pas de perte
  # par la toiture (paroi adjacente = paroi entre deux ambiances au même
  # T°). Idem pour le plancher bas quand un lot est chauffé en-dessous.
  # NF EN ISO 13789 : b ≈ 0 dans ces cas. Notre §1 (§1 du doc) reprend
  # cette convention (ADEME 3CL sur les parties courantes uniquement).
  #
  # Ces coefficients ne s'appliquent QUE si property_type=:appartement
  # ET position_lot est explicitement connue (dernier_etage / rdc /
  # etage_intermediaire). Pour position_lot :inconnu ou nil, on retombe
  # sur B_EXTERIEUR / B_PLANCHER_BAS — comportement conservateur : on
  # préfère surestimer les déperditions plutôt qu'inventer une
  # mitoyenneté non validée.
  B_MITOYEN_CHAUFFE = 0.0

  # §1 — forfait ponts thermiques (fourchette 5–20 %), milieu
  COEF_PT = 0.12

  # ── §5bis — degrés-heures par zone climatique (arrêté 17/10/2012) ──────
  DH14 = { h1: 42_030, h2: 33_300, h3: 22_200 }.freeze

  # §5bis — rendements génération (milieu de fourchette)
  RG = {
    gaz:         0.95,  # chaudière gaz condensation (§5bis 0,90–1,0)
    fioul:       0.75,  # chaudière fioul ancienne   (§5bis 0,70–0,80)
    electricite: 1.00,  # convecteurs effet Joule    (§5bis)
    bois:        0.75,  # poêle bûches récent (hypothèse Lauze)
    pac:         3.00,  # PAC air/eau COP saisonnier (§5bis)
  }.freeze
  # §5bis émission × distribution × régulation (fourchette 0,85–0,95).
  # §5ter — borne basse retenue : parc cible Lauze = passoires < 1975 =
  # installations vieillissantes, radiateurs surdimensionnés, régulation
  # imparfaite. Bumper à 0,90 pour installations récentes/PAC modernes
  # serait défensible (modifie ~6 % la conso finale).
  RERD_DEFAUT = 0.85

  # ── §5a — facteur énergie primaire (arrêté 13/08/2025) ─────────────────
  FACTEUR_EP = {
    gaz: 1.0, fioul: 1.0, bois: 1.0,
    electricite: 1.9,  # depuis 01/01/2026 (était 2,3)
    pac:         1.9,  # PAC = électricité
  }.freeze

  # ── §5b — facteur carbone (kgCO₂/kWh d'énergie finale, ACV) ────────────
  FACTEUR_CO2 = {
    gaz:         0.234,
    fioul:       0.300,
    electricite: 0.079,
    pac:         0.079,
    bois:        0.013,
  }.freeze

  # ── §2 — seuils des 7 classes (logements > 40 m², altitude < 800 m) ────
  SEUILS_EP  = [[70,'A'],[110,'B'],[180,'C'],[250,'D'],[330,'E'],[420,'F'],[Float::INFINITY,'G']].freeze
  SEUILS_CO2 = [[6,'A'],[11,'B'],[30,'C'],[50,'D'],[70,'E'],[100,'F'],[Float::INFINITY,'G']].freeze

  # ── §1 — DR : 0,34 × n × V (W/K). 0,34 = ρ_air·cp_air/3600 (constante phys.)
  CONST_DR = 0.34
  # §5ter — n par défaut bâti < 1975 sans VMC : borne haute des valeurs
  # conventionnelles (RT 2005 prenait 0,6 ; les bâtis < 1975 ont des
  # défauts d'étanchéité réels mesurés à 1,0–1,5 vol/h). Cohérent avec
  # la cible §5bis « renouv. air = 20–25 % du GV » sur une passoire.
  N_VENTILATION = {
    aucune_vmc:      1.0,
    vmc_simple_flux: 0.5,
    vmc_double_flux: 0.15,
  }.freeze

  # ── Hypothèses de modélisation Lauze (non réglementaires, §9 du doc) ───
  HAUTEUR_SOUS_PLAFOND_DEFAUT = 2.5
  NIVEAUX_DEFAUT              = 2
  RATIO_TOITURE_RAMPANTS      = 1.15   # combles aménagés ~30°
  RATIO_TOITURE_PLATE         = 1.0    # combles perdus / toit terrasse
  M2_PAR_FENETRE_DEFAUT       = 1.5    # fenêtre ancienne typique
  RATIO_SURFACE_FENETRES      = 1.0/6  # ratio RT 1/6e si rien de fourni

  # Coef. d'apports gratuits (soleil + occupation) ; Bch = COEF × GV × DH/1000.
  # Simplification Lauze ; la 3CL fine calcule X^a/(X^a-1). §5ter — 0,95
  # conservateur pour passoire mal orientée (faibles apports utiles).
  COEF_APPORTS_DEFAUT = 0.95

  # ECS forfait (kWh/m²/an EF). Justification physique en §5ter du doc :
  # besoin utile = ρ·c · V · ΔT · 365 ÷ 1000 = 1,162 × 100 × 35 × 365 / 1000
  # ≈ 1 485 kWh/an (V = 2 occupants × 50 L/j ; ΔT = 35 K conv. 3CL).
  # Conso finale = besoin ÷ rendement combiné (ballon × distribution).
  # Hypothèse Lauze N=2 (foyer non interrogé) — borne basse délibérée vs
  # la 3CL réglementaire (N = 0,025 × Shab) ; voir §5ter.
  ECS_FORFAIT_EF = {
    gaz: 15, fioul: 15, bois: 15,  # ballon perf. OU cumulus élec sép. (R≈0,82)
    electricite: 17,               # cumulus standard (R≈0,73)
    pac:         7,                # CET thermodynamique COP_ECS ≈ 2,5
  }.freeze

  # Type de production ECS, indépendant de l'énergie de chauffage.
  #   :standard — l'ECS suit l'énergie de chauffage (comportement historique) :
  #               ballon perf. sur bâti gaz/fioul/bois, cumulus sur bâti élec,
  #               ECS intégrée à la PAC quand le chauffage est une PAC.
  #   :cet      — chauffe-eau thermodynamique (CET, COP_ECS ≈ 2,5). Toujours
  #               électrique — bascule energie_ecs sur :pac, quelle que soit
  #               l'énergie de chauffage. Anti-double-compte : quand le
  #               chauffage est déjà :pac, :cet donne le même résultat que
  #               :standard (la PAC couvre déjà l'ECS ; ECS_FORFAIT_EF[:pac]
  #               s'applique dans les deux cas).
  TYPES_ECS = %i[standard cet].freeze

  ORDRE_CLASSES = %w[A B C D E F G].freeze

  def self.call(**kw) = new(**kw).call

  def initialize(
    surface_habitable:,
    annee_construction:,
    energie_chauffage:,
    zone_climatique: :h1,
    isolation_murs: :non_isole,
    isolation_toiture: :non_isole,
    isolation_plancher_bas: :non_isole,
    isolation_menuiseries: :non_isole,
    niveaux: NIVEAUX_DEFAUT,
    hauteur_sous_plafond: HAUTEUR_SOUS_PLAFOND_DEFAUT,
    toiture_rampants: false,
    ventilation: :aucune_vmc,
    surface_murs: nil,
    surface_toiture: nil,
    surface_plancher_bas: nil,
    surface_fenetres: nil,
    nombre_fenetres: nil,
    # Mitoyenneté verticale (optionnelle — backward-compat).
    # Quand les deux sont nil, comportement identique à avant :
    # b_toiture=1.0, b_plancher_bas=0.8. Une maison ou un appartement de
    # position inconnue prend le comportement conservateur historique.
    property_type: nil,
    position_lot: nil,
    # Switches / overrides de calibrage — restent ouverts tant que le
    # §5ter du doc n'est pas figé.
    inclure_ecs: false,
    # Type de production ECS (cf. TYPES_ECS). :standard = comportement
    # historique (ECS suit l'énergie de chauffage), :cet = chauffe-eau
    # thermodynamique électrique. Défaut :standard → non-régression.
    type_ecs: :standard,
    coef_apports: COEF_APPORTS_DEFAUT,
    n_ventilation_override: nil,
    rerd: RERD_DEFAUT
  )
    @s_hab = surface_habitable.to_f
    @annee = annee_construction.to_i
    @energie = energie_chauffage.to_sym
    @zone = zone_climatique.to_sym
    @iso = {
      murs: isolation_murs.to_sym,
      toiture: isolation_toiture.to_sym,
      plancher_bas: isolation_plancher_bas.to_sym,
      menuiseries: isolation_menuiseries.to_sym
    }
    @niveaux = niveaux.to_i
    @h = hauteur_sous_plafond.to_f
    @toiture_rampants = toiture_rampants
    @ventilation = ventilation.to_sym
    @property_type = property_type&.to_sym
    @position_lot  = position_lot&.to_sym
    @inclure_ecs = inclure_ecs
    @type_ecs    = type_ecs.to_sym
    @coef_apports = coef_apports
    @n_override = n_ventilation_override
    @rerd = rerd

    @s_sol = @s_hab / @niveaux
    @s_mur     = surface_murs        || defaut_surface_murs
    @s_toiture = surface_toiture     || defaut_surface_toiture
    @s_pb      = surface_plancher_bas || @s_sol
    @s_fen     = surface_fenetres ||
                 (nombre_fenetres ? nombre_fenetres * M2_PAR_FENETRE_DEFAUT
                                  : @s_hab * RATIO_SURFACE_FENETRES)
  end

  def call
    gv_data = calcul_gv
    bch = @coef_apports * gv_data[:gv] * DH14.fetch(@zone) / 1000.0
    conso_ch  = bch / (RG.fetch(@energie) * @rerd)
    ecs_energie = energie_ecs
    conso_ecs = @inclure_ecs ? ECS_FORFAIT_EF.fetch(ecs_energie) * @s_hab : 0.0
    conso_finale = conso_ch + conso_ecs

    # Cas standard (ECS suit l'énergie de chauffage) : chemin bit-exact
    # historique — un unique facteur EP/CO2 sur la conso finale totale.
    # Cas :cet (ECS électrique) : facteurs EP/CO2 différenciés par flux
    # énergétique — le facteur électrique 1,9 EP et 0,079 CO2 s'applique
    # à la conso ECS quand l'ECS bascule sur :pac.
    if ecs_energie == @energie
      ep  = conso_finale * FACTEUR_EP.fetch(@energie)
      co2 = conso_finale * FACTEUR_CO2.fetch(@energie)
    else
      ep  = conso_ch  * FACTEUR_EP.fetch(@energie)  + conso_ecs * FACTEUR_EP.fetch(ecs_energie)
      co2 = conso_ch  * FACTEUR_CO2.fetch(@energie) + conso_ecs * FACTEUR_CO2.fetch(ecs_energie)
    end
    ep_m2  = ep / @s_hab
    co2_m2 = co2 / @s_hab
    cl_e = classe(ep_m2, SEUILS_EP)
    cl_c = classe(co2_m2, SEUILS_CO2)

    {
      conso_ep_m2: ep_m2.round(1),
      conso_carbone_m2: co2_m2.round(1),
      classe_energie: cl_e,
      classe_carbone: cl_c,
      classe_finale: pire(cl_e, cl_c),
      _details: {
        surfaces: { mur: @s_mur.round(1), toit: @s_toiture.round(1),
                    plancher_bas: @s_pb.round(1), fenetres: @s_fen.round(1) },
        gv: gv_data[:gv].round(1),
        gv_breakdown: gv_data[:breakdown],
        hierarchie_pct: gv_data[:breakdown].transform_values { |v|
          (v * 100.0 / gv_data[:gv]).round(1)
        },
        bch_kwh: bch.round,
        conso_chauffage_final_kwh: conso_ch.round,
        conso_ecs_final_kwh: conso_ecs.round,
        conso_finale_totale_kwh: conso_finale.round
      }
    }
  end

  private

  # Énergie effectivement consommée par l'ECS. Défaut :standard → l'ECS
  # suit l'énergie de chauffage (rétro-compat). :cet → l'ECS est produite
  # par un chauffe-eau thermodynamique électrique, indexé sur :pac
  # (COP_ECS ≈ 2,5 → 7 kWhEF/m²) avec facteurs EP/CO2 de l'électricité.
  # Cas particulier :pac + :cet → energie_ecs reste :pac (déjà couvert
  # par la PAC) : anti-double-compte intrinsèque.
  def energie_ecs
    @type_ecs == :cet ? :pac : @energie
  end

  # Coefficient b de la paroi haute (toiture). Zéro quand la paroi est
  # adjacente à un lot chauffé (appartement en RDC ou étage
  # intermédiaire). Sinon comportement historique (B_EXTERIEUR = 1.0).
  # NF EN ISO 13789 §5.3.
  def b_toiture
    return B_EXTERIEUR unless @property_type == :appartement
    case @position_lot
    when :rdc, :etage_intermediaire then B_MITOYEN_CHAUFFE
    else B_EXTERIEUR # :dernier_etage → toiture réelle ; :inconnu / nil → conservateur
    end
  end

  # Coefficient b du plancher bas. Zéro quand la paroi est adjacente à
  # un lot chauffé (appartement en dernier étage ou intermédiaire).
  # Sinon comportement historique (B_PLANCHER_BAS = 0.8, vide sanitaire).
  def b_plancher_bas
    return B_PLANCHER_BAS unless @property_type == :appartement
    case @position_lot
    when :dernier_etage, :etage_intermediaire then B_MITOYEN_CHAUFFE
    else B_PLANCHER_BAS # :rdc → dalle réelle ; :inconnu / nil → conservateur
    end
  end

  def defaut_surface_murs
    perimetre = 4 * Math.sqrt(@s_sol)         # maison carrée
    brut = perimetre * @niveaux * @h
    fen_defaut = @s_hab * RATIO_SURFACE_FENETRES
    [brut - fen_defaut, 0].max
  end

  def defaut_surface_toiture
    @s_sol * (@toiture_rampants ? RATIO_TOITURE_RAMPANTS : RATIO_TOITURE_PLATE)
  end

  def calcul_gv
    dp_murs = B_EXTERIEUR    * @s_mur     * u_courant(:murs)
    dp_toit = b_toiture      * @s_toiture * u_courant(:toiture)
    dp_pb   = b_plancher_bas * @s_pb      * u_courant(:plancher_bas)
    dp_fen  = B_EXTERIEUR    * @s_fen     * u_courant(:menuiseries)
    parois  = dp_murs + dp_toit + dp_pb + dp_fen

    pt = COEF_PT * parois
    n  = @n_override || N_VENTILATION.fetch(@ventilation)
    qv = n * (@s_hab * @h)
    dr = CONST_DR * qv

    {
      gv: parois + pt + dr,
      breakdown: {
        murs: dp_murs.round(1), toit: dp_toit.round(1),
        plancher_bas: dp_pb.round(1), fenetres: dp_fen.round(1),
        pt: pt.round(1), renouv_air: dr.round(1)
      }
    }
  end

  def u_courant(poste)
    case poste
    when :murs
      u = case @iso[:murs]
          when :isole   then 1.0 / (R_ITI_MIN + R_RESIDUELLE_PAROI)
          when :partiel then UMUR_PARTIEL                    # §3bis
          else               UMUR_NON_ISOLE
          end
      [u, UMUR_PLAFOND_CALCUL].min     # Min(Umur ; 2) — §3
    when :toiture
      case @iso[:toiture]
      when :isole   then 1.0 / (R_COMBLES_PERDUS_MIN + R_RESIDUELLE_PAROI)
      when :partiel then UPH_PARTIEL                          # §3bis
      else               UPH_NON_ISOLE
      end
    when :plancher_bas
      case @iso[:plancher_bas]
      when :isole   then 1.0 / (R_PLANCHER_BAS_MIN + R_RESIDUELLE_PAROI)
      when :partiel then UPB_PARTIEL                          # §3bis
      else               UPB_DEFAUT
      end
    when :menuiseries
      case @iso[:menuiseries]
      when :isole   then UW_DOUBLE_VITRAGE
      when :partiel then UW_PARTIEL                           # §3bis
      else               UW_SIMPLE_VITRAGE
      end
    end
  end

  def classe(valeur, seuils)
    seuils.each { |max, c| return c if valeur <= max }
  end

  def pire(c1, c2)
    ORDRE_CLASSES[[ORDRE_CLASSES.index(c1), ORDRE_CLASSES.index(c2)].max]
  end
end
