# app/services/aid_calculator_service.rb
#
# Calcule les aides éligibles pour une propriété donnée.
#
# Sources officielles :
#   - MaPrimeRénov' Parcours accompagné (rénovation d'ampleur) :
#       ANAH / economie.gouv.fr / PDF "MaPrimeRénov' Mode d'emploi" (Mars 2026)
#       Fiches 02/04/06/08 — taux 80/60/45/10 % selon profil
#   - MaPrimeRénov' Par geste (rénovation par geste) :
#       PDF Fiches 01/03/05/07 — forfaits par équipement
#       SUP non éligible MPR en par geste (CEE seul)
#   - Certificats d'Économies d'Énergie (CEE) :
#       Forfaits indicatifs du PDF MPR pages 17/21/25/29 (colonne CEE)
#   - Éco-PTZ : service-public.fr / effy.fr (grille complète 2026)
#   - Grand Nancy : Règlement d'intervention maisons individuelles
#       (délibération 06/06/2024, en vigueur 01/10/2024, valable jusqu'au 31/12/2029)
#
# IMPORTANT : L'éco-PTZ est un PRÊT, pas une subvention.
# Il est retourné dans [:financement], jamais dans [:total_subventions].
#
# Usage :
#   result = AidCalculatorService.new(property).call
#   result[:total_subventions]   # => 18_500.0  (MPR + CEE + Grand Nancy)
#   result[:subventions]         # => [{ name: "MaPrimeRénov'...", amount: 16000, ... }, ...]
#   result[:financement]         # => [{ name: "Éco-PTZ", amount: 30000, nature: :pret, ... }]
#   result[:errors]              # => [...]
#
# Filtrage par cases cochées (travaux_selection sur Property) :
#   Par défaut, le service lit tous les équipements/surfaces présents sur
#   la propriété. Pour que le calcul reflète uniquement les macro-postes
#   cochés par le propriétaire dans la card "Rénovation énergétique" :
#
#     AidCalculatorService.new(property, travaux_actifs: property.travaux_actifs).call
#
#   Sémantique :
#     travaux_actifs: nil   → aucun filtre (lit tout, comportement historique).
#     travaux_actifs: []    → filtre strict, zéro équipement autorisé.
#                             Utile quand l'utilisateur a tout décoché.
#     travaux_actifs: [...] → seuls les équipements et surfaces rattachés à
#                             ces macro-postes (via TravauxMapperService::MACRO_TO_*)
#                             entrent dans le calcul MPR Par geste, CEE et
#                             Grand Nancy Isolation.
#
#   Pour les biens fraîchement créés dont travaux_selection jsonb est encore
#   vide ({}), le controller doit passer nil plutôt que [] pour ne pas
#   ramener les aides à zéro avant que l'utilisateur ait pu interagir
#   avec l'UI.

class AidCalculatorService

  # ================================================================
  # MPR Parcours accompagné (rénovation d'ampleur) — Fiches 02/04/06/08
  # ================================================================
  MPR_TAUX_2026 = {
    "tres_modeste"  => 0.80,
    "modeste"       => 0.60,
    "intermediaire" => 0.45,
    "superieur"     => 0.10
  }.freeze

  # Plafonds de dépenses HT éligibles selon le saut de classes DPE
  MPR_PLAFOND_TRAVAUX_HT = {
    2 => 30_000,   # saut de 2 classes
    3 => 40_000,   # saut de 3 classes
    4 => 40_000    # saut de 4 classes ou +
  }.freeze

  # Cap cumul MPR + autres aides, en % du montant TTC des travaux
  # Source : PDF Fiches 02/04/06/08 "en additionnant l'ensemble des aides..."
  MPR_AMPLEUR_CUMUL_CAP = {
    "tres_modeste"  => 1.00,  # "ne pourra pas dépasser le montant TTC"
    "modeste"       => 0.90,
    "intermediaire" => 0.80,
    "superieur"     => 0.50
  }.freeze

  # ================================================================
  # MPR Par geste — Fiches 01/03/05/07
  # Forfaits en € (unitaires) ou €/m² (surfaces)
  # SUP n'est pas éligible à MPR en par geste → hash vide
  # ================================================================
  MPR_PAR_GESTE_FORFAITS = {
    "tres_modeste" => {
      # Chauffage / ECS
      "raccordement_reseau_chaleur" => 1_200,
      "chauffe_eau_thermo"          => 1_200,
      "pac_air_eau"                 => 5_000,
      "pac_geothermique"            => 11_000,
      "chauffe_eau_solaire"         => 4_000,
      "systeme_solaire_combine"     => 10_000,
      "pvt_eau"                     => 2_500,
      "poele_buches"                => 1_250,
      "poele_granules"              => 1_250,
      "insert_foyer"                => 1_250,
      # Isolation (par m² ou par équipement)
      "surface_rampants"            => 25,    # €/m² (rampants + combles aménagés)
      "surface_toiture_terrasse"    => 75,    # €/m²
      "nb_parois_vitrees"           => 100,   # €/équipement
      # Autres
      "audit_energetique"           => 500,
      "depose_fioul"                => 1_200,
      "vmc_double_flux"             => 2_500
    }.freeze,

    "modeste" => {
      "raccordement_reseau_chaleur" => 800,
      "chauffe_eau_thermo"          => 800,
      "pac_air_eau"                 => 4_000,
      "pac_geothermique"            => 9_000,
      "chauffe_eau_solaire"         => 3_000,
      "systeme_solaire_combine"     => 8_000,
      "pvt_eau"                     => 2_000,
      "poele_buches"                => 1_000,
      "poele_granules"              => 1_000,
      "insert_foyer"                => 750,
      "surface_rampants"            => 20,
      "surface_toiture_terrasse"    => 60,
      "nb_parois_vitrees"           => 80,
      "audit_energetique"           => 400,
      "depose_fioul"                => 800,
      "vmc_double_flux"             => 2_000
    }.freeze,

    "intermediaire" => {
      "raccordement_reseau_chaleur" => 400,
      "chauffe_eau_thermo"          => 400,
      "pac_air_eau"                 => 3_000,
      "pac_geothermique"            => 6_000,
      "chauffe_eau_solaire"         => 2_000,
      "systeme_solaire_combine"     => 4_000,
      "pvt_eau"                     => 1_000,
      "poele_buches"                => 500,
      "poele_granules"              => 750,
      "insert_foyer"                => 500,
      "surface_rampants"            => 15,
      "surface_toiture_terrasse"    => 40,
      "nb_parois_vitrees"           => 40,
      "audit_energetique"           => 300,
      "depose_fioul"                => 400,
      "vmc_double_flux"             => 1_500
    }.freeze,

    # Fiche 07 — SUP par geste : MPR non éligible, CEE uniquement
    "superieur" => {}.freeze
  }.freeze

  # Forfaits CEE indicatifs — Fiches 01/03/05/07 colonne "Montants approximatifs des CEE"
  # Les valeurs varient selon le profil (Coup de pouce TMO/MO, standards INT/SUP)
  CEE_FORFAITS = {
    # surface_ite / surface_iti : opérations standardisées BAR-EN-102 (ITE)
    # et BAR-EN-101 (ITI). Montants indicatifs, cohérents avec les autres
    # postes surfaciques de la grille. ITE > ITI partout (conformément à
    # l'écart d'efficacité thermique et de rémunération CEE observé en
    # pratique sur ces deux opérations).
    "tres_modeste" => {
      "raccordement_reseau_chaleur" => 700,
      "chauffe_eau_thermo"          => 110,
      "pac_air_eau"                 => 4_000,
      "pac_geothermique"            => 5_000,
      "chauffe_eau_solaire"         => 160,
      "systeme_solaire_combine"     => 5_000,
      "pvt_eau"                     => 170,
      "poele_buches"                => 800,
      "poele_granules"              => 800,
      "insert_foyer"                => 800,
      "surface_rampants"            => 12,
      "surface_toiture_terrasse"    => 9,
      "surface_ite"                 => 15,
      "surface_iti"                 => 9,
      "nb_parois_vitrees"           => 44,
      "vmc_double_flux"             => 300
    }.freeze,

    "modeste" => {
      "raccordement_reseau_chaleur" => 700,
      "chauffe_eau_thermo"          => 100,
      "pac_air_eau"                 => 4_000,
      "pac_geothermique"            => 5_000,
      "chauffe_eau_solaire"         => 140,
      "systeme_solaire_combine"     => 5_000,
      "pvt_eau"                     => 150,
      "poele_buches"                => 800,
      "poele_granules"              => 800,
      "insert_foyer"                => 800,
      "surface_rampants"            => 11,
      "surface_toiture_terrasse"    => 7.50,
      "surface_ite"                 => 12,
      "surface_iti"                 => 7,
      "nb_parois_vitrees"           => 38,
      "vmc_double_flux"             => 260
    }.freeze,

    "intermediaire" => {
      "raccordement_reseau_chaleur" => 450,
      "chauffe_eau_thermo"          => 100,
      "pac_air_eau"                 => 2_500,
      "pac_geothermique"            => 5_000,
      "chauffe_eau_solaire"         => 140,
      "systeme_solaire_combine"     => 5_000,
      "pvt_eau"                     => 150,
      "poele_buches"                => 500,
      "poele_granules"              => 500,
      "insert_foyer"                => 500,
      "surface_rampants"            => 11,
      "surface_toiture_terrasse"    => 7.50,
      "surface_ite"                 => 12,
      "surface_iti"                 => 7,
      "nb_parois_vitrees"           => 38,
      "vmc_double_flux"             => 260
    }.freeze,

    # SUP = mêmes forfaits CEE qu'INT (pas de Coup de pouce mais CEE standard)
    "superieur" => {
      "raccordement_reseau_chaleur" => 450,
      "chauffe_eau_thermo"          => 100,
      "pac_air_eau"                 => 2_500,
      "pac_geothermique"            => 5_000,
      "chauffe_eau_solaire"         => 140,
      "systeme_solaire_combine"     => 5_000,
      "pvt_eau"                     => 150,
      "poele_buches"                => 500,
      "poele_granules"              => 500,
      "insert_foyer"                => 500,
      "surface_rampants"            => 11,
      "surface_toiture_terrasse"    => 7.50,
      "surface_ite"                 => 12,
      "surface_iti"                 => 7,
      "nb_parois_vitrees"           => 38,
      "vmc_double_flux"             => 260
    }.freeze
  }.freeze

  # Cap cumul MPR + CEE en par geste, en % du TTC
  # Source : PDF Fiches 01/03/05 "votre prime ne pourra pas dépasser X % du montant TTC"
  MPR_PAR_GESTE_CUMUL_CAP = {
    "tres_modeste"  => 0.90,
    "modeste"       => 0.75,
    "intermediaire" => 0.60,
    "superieur"     => 1.00   # pas de cap spécifique MPR (pas de MPR), CEE seul
  }.freeze

  # Libellés humains pour l'affichage (basis / details)
  POSTE_LABELS = {
    "pac_air_eau"                 => "PAC air/eau",
    "pac_geothermique"            => "PAC géothermique",
    "chauffe_eau_thermo"          => "Chauffe-eau thermodynamique",
    "chauffe_eau_solaire"         => "Chauffe-eau solaire",
    "systeme_solaire_combine"     => "Système solaire combiné",
    "pvt_eau"                     => "PVT eau",
    "poele_buches"                => "Poêle à bûches",
    "poele_granules"              => "Poêle à granulés",
    "insert_foyer"                => "Insert / foyer fermé",
    "raccordement_reseau_chaleur" => "Raccordement réseau de chaleur",
    "depose_fioul"                => "Dépose cuve à fioul",
    "vmc_double_flux"             => "VMC double flux",
    "audit_energetique"           => "Audit énergétique",
    "surface_rampants"            => "Isolation rampants / combles aménagés",
    "surface_toiture_terrasse"    => "Isolation toiture terrasse",
    "surface_ite"                 => "Isolation murs par l'extérieur (ITE)",
    "surface_iti"                 => "Isolation murs par l'intérieur (ITI)",
    "surface_sarking"             => "Sarking (toiture par l'extérieur)",
    "surface_combles_perdus"      => "Isolation combles perdus",
    "surface_plancher_bas"        => "Isolation plancher bas",
    "nb_parois_vitrees"           => "Remplacement fenêtres simple → double vitrage"
  }.freeze

  # ================================================================
  # Éco-PTZ (FINANCEMENT, pas subvention)
  # ================================================================
  ECO_PTZ_GRILLE = {
    1 => 15_000,
    2 => 25_000,
    3 => 30_000
  }.freeze
  ECO_PTZ_RENO_GLOBALE = 50_000

  # ================================================================
  # Grand Nancy — aide isolation (€/m²)
  # Source : Règlement d'intervention maisons individuelles, Art. 3, p.6
  # ================================================================
  GN_ISOLATION_MODESTE = {
    "ite"              => 40,
    "iti"              => 10,
    "sarking"          => 50,
    "combles_perdus"   => 10,
    "toiture_terrasse" => 40,
    "plancher_bas"     => 15
  }.freeze

  GN_ISOLATION_SUPERIEUR = {
    "ite"              => 30,
    "iti"              => 5,
    "sarking"          => 40,
    "combles_perdus"   => 5,
    "toiture_terrasse" => 30,
    "plancher_bas"     => 10
  }.freeze

  # Grand Nancy — rénovation globale (% dépenses MPR)
  GN_RENO_GLOBALE_TAUX = {
    "tres_modeste"  => { taux_ab: 0.25, taux_ab_passoire: 0.15, plafond: 10_000 },
    "modeste"       => { taux_ab: 0.25, taux_ab_passoire: 0.15, plafond:  7_500 },
    "intermediaire" => { taux_ab: 0.15, taux_ab_passoire: 0.05, plafond:  5_000 },
    "superieur"     => { taux_ab: 0.15, taux_ab_passoire: 0.05, plafond:  2_500 }
  }.freeze

  def initialize(property, travaux_actifs: nil)
    @p                   = property
    # Sémantique :
    #   nil  (défaut) → aucun filtre, lit tous les équipements/surfaces
    #                   présents sur la propriété (comportement historique).
    #   []            → filtre strict, zéro macro-poste autorisé.
    #                   Utile pour le cas "utilisateur a tout décoché".
    #   [...]         → seuls les macro-postes listés entrent dans le calcul.
    @travaux_actifs      = travaux_actifs
    @subventions         = []
    @aides_potentielles  = []   # aides non éligibles actuellement mais qui pourraient l'être
    @financement         = []
    @errors              = []
  end

  def call
    calculate_mpr_and_cee
    calculate_eco_ptz
    calculate_grand_nancy_isolation
    calculate_grand_nancy_renovation_globale

    {
      subventions:        @subventions,
      aides_potentielles: @aides_potentielles,
      financement:        @financement,
      total_subventions:  @subventions.sum { |a| a[:amount] },
      errors:             @errors,
      calculated_at:      Time.current
    }
  end

  private

  # ================================================================
  # Orchestrateur MPR + CEE
  # Route vers Ampleur (parcours accompagné) ou Par geste selon éligibilité
  # ================================================================
  def calculate_mpr_and_cee
    unless @p.income_bracket.present?
      @errors << "Revenus non renseignés — aides MPR / CEE non calculables"
      return
    end

    # Condition ancienneté ≥ 15 ans (commune aux deux parcours)
    if @p.construction_year.present? && @p.construction_year.to_i > (Date.today.year - 15)
      @errors << "MaPrimeRénov' : logement doit avoir ≥ 15 ans (construit en #{@p.construction_year})"
      return
    end

    if eligible_parcours_accompagne?
      calculate_mpr_ampleur
    else
      calculate_mpr_par_geste_and_cee
    end
  end

  # ================================================================
  # MPR Parcours accompagné (rénovation d'ampleur) — Fiches 02/04/06/08
  # ================================================================
  # Conditions :
  #   - DPE actuel E, F ou G
  #   - ≥ 2 gestes d'isolation + ventilation + saut ≥ 2 classes
  #   - Accompagnateur Rénov' obligatoire
  # ================================================================
  def calculate_mpr_ampleur
    rule = AidRule.find_by(slug: "mpr_parcours_accompagne", active: true)
    return unless rule

    dpe_actuel = @p.dpe_class&.upcase
    unless %w[E F G].include?(dpe_actuel)
      @errors << "MPR Rénovation d'ampleur réservée aux logements E, F ou G (DPE actuel : #{dpe_actuel || '?'})"
      return
    end

    taux       = MPR_TAUX_2026[@p.income_bracket] || 0
    saut       = dpe_saut(@p.dpe_class&.upcase, @p.dpe_target&.upcase)
    plafond_ht = MPR_PLAFOND_TRAVAUX_HT[[saut, 4].min] || MPR_PLAFOND_TRAVAUX_HT[2]
    base_ht    = [estimated_cost_ht, plafond_ht].min
    montant    = (base_ht * taux).round

    # Cap cumul TTC : total aides ≤ X % TTC selon profil
    cap_ratio  = MPR_AMPLEUR_CUMUL_CAP[@p.income_bracket] || 1.0
    budget_ttc = estimated_budget_ttc
    cap_amount = (budget_ttc * cap_ratio).round

    if montant > cap_amount && cap_amount > 0
      @errors << "MPR Ampleur écrêtée au cap cumul #{(cap_ratio * 100).to_i} % TTC (#{cap_amount} €)"
      montant = cap_amount
    end

    @subventions << {
      slug:        rule.slug,
      name:        rule.name,
      type:        "mpr",
      nature:      :subvention,
      amount:      montant,
      basis:       "#{(taux * 100).to_i} % × #{base_ht.to_i} € HT (plafond #{plafond_ht.to_i} € HT, saut #{saut} classes)",
      source:      rule.source_label,
      valid_until: rule.valid_until,
      confidence:  :medium
    }

    # CEE cumulable avec MPR Parcours Accompagné : dispositif fournisseurs
    # d'énergie indépendant du parcours MPR. On l'ajoute systématiquement.
    calculate_cee_standalone
  end

  # ================================================================
  # CEE seul : calcul indépendant du parcours MPR choisi.
  # Additionne les forfaits CEE des travaux structurés selon le profil revenus.
  # Appelé par calculate_mpr_ampleur (Parcours Accompagné) pour que le CEE
  # ne soit pas oublié, car il est cumulable avec MPR Ampleur.
  # ================================================================
  def calculate_cee_standalone
    bracket      = @p.income_bracket
    cee_forfaits = CEE_FORFAITS[bracket] || {}
    travaux      = structured_travaux
    return if travaux.empty?

    cee_total = 0
    cee_details = []

    travaux.each do |poste_code, data|
      quantite = data[:quantite].to_f
      next if quantite <= 0
      next unless (cee_unit = cee_forfaits[poste_code])

      montant = (cee_unit * quantite).round
      next unless montant > 0

      label = POSTE_LABELS[poste_code] || poste_code.humanize
      cee_total += montant
      cee_details << "#{label} (#{format_quantite(quantite, data[:unite])}) #{montant} €"
    end

    return if cee_total == 0

    rule = AidRule.find_by(slug: "cee", active: true)
    @subventions << {
      slug:        rule&.slug || "cee",
      name:        rule&.name || "Certificats d'Économies d'Énergie",
      type:        "cee",
      nature:      :subvention,
      amount:      cee_total,
      basis:       cee_details.take(3).join(" · ") + (cee_details.size > 3 ? " · +#{cee_details.size - 3}" : ""),
      source:      rule&.source_label || "Arrêté CEE — montants indicatifs",
      valid_until: rule&.valid_until,
      confidence:  :low,
      note:        "Les montants CEE varient selon les fournisseurs — à comparer avant travaux."
    }
  end

  # ================================================================
  # MPR Par geste + CEE — Fiches 01/03/05/07
  # ================================================================
  # Logique :
  #   1. Lister les travaux structurés (surfaces + équipements)
  #   2. Pour chaque travail, additionner forfait MPR et forfait CEE
  #   3. SUP : MPR = 0, CEE seul
  #   4. Appliquer le cap de cumul MPR+CEE (90/75/60 % TTC)
  # ================================================================
  def calculate_mpr_par_geste_and_cee
    bracket      = @p.income_bracket
    mpr_forfaits = MPR_PAR_GESTE_FORFAITS[bracket] || {}
    cee_forfaits = CEE_FORFAITS[bracket]           || {}
    travaux      = structured_travaux

    if travaux.empty?
      @errors << "Aucun travail détaillé détecté — relancez l'analyse pour obtenir les forfaits MPR Par geste"
      return
    end

    mpr_total, cee_total = 0, 0
    mpr_details, cee_details = [], []

    travaux.each do |poste_code, data|
      quantite = data[:quantite].to_f
      next if quantite <= 0

      label = POSTE_LABELS[poste_code] || poste_code.humanize

      if (mpr_unit = mpr_forfaits[poste_code])
        montant = (mpr_unit * quantite).round
        if montant > 0
          mpr_total += montant
          mpr_details << "#{label} (#{format_quantite(quantite, data[:unite])}) #{montant} €"
        end
      end

      if (cee_unit = cee_forfaits[poste_code])
        montant = (cee_unit * quantite).round
        if montant > 0
          cee_total += montant
          cee_details << "#{label} (#{format_quantite(quantite, data[:unite])}) #{montant} €"
        end
      end
    end

    return if mpr_total == 0 && cee_total == 0

    # Cap cumul TTC
    cap_ratio  = MPR_PAR_GESTE_CUMUL_CAP[bracket] || 1.0
    budget_ttc = estimated_budget_ttc
    cap_amount = (budget_ttc * cap_ratio).round

    if (mpr_total + cee_total) > cap_amount && cap_amount > 0
      excess    = (mpr_total + cee_total) - cap_amount
      # Écrêtement sur CEE en priorité (MPR = aide principale)
      reduce_cee = [excess, cee_total].min
      cee_total -= reduce_cee
      remaining_excess = excess - reduce_cee
      mpr_total  -= remaining_excess if remaining_excess > 0
      @errors << "Cumul MPR + CEE écrêté au cap #{(cap_ratio * 100).to_i} % TTC (#{cap_amount} €)"
    end

    if mpr_total > 0
      rule = AidRule.find_by(slug: "mpr_par_geste", active: true)
      @subventions << {
        slug:       rule&.slug || "mpr_par_geste",
        name:       rule&.name || "MaPrimeRénov' Par geste",
        type:       "mpr",
        nature:     :subvention,
        amount:     mpr_total,
        basis:      mpr_details.take(3).join(" · ") + (mpr_details.size > 3 ? " · +#{mpr_details.size - 3}" : ""),
        source:     rule&.source_label || "ANAH / France Rénov' (Mars 2026)",
        valid_until: rule&.valid_until,
        confidence: :medium
      }
    end

    if cee_total > 0
      rule = AidRule.find_by(slug: "cee", active: true)
      @subventions << {
        slug:       rule&.slug || "cee",
        name:       rule&.name || "Certificats d'Économies d'Énergie",
        type:       "cee",
        nature:     :subvention,
        amount:     cee_total,
        basis:      cee_details.take(3).join(" · ") + (cee_details.size > 3 ? " · +#{cee_details.size - 3}" : ""),
        source:     rule&.source_label || "Arrêté CEE — montants indicatifs",
        valid_until: rule&.valid_until,
        confidence: :low,
        note:       "Les montants CEE varient selon les fournisseurs — à comparer avant travaux."
      }
    end
  end

  # ================================================================
  # Éco-PTZ (inchangé)
  # ================================================================
  def calculate_eco_ptz
    rule = AidRule.find_by(slug: "eco_ptz", active: true)
    return unless rule

    if @p.construction_year.present? && @p.construction_year.to_i > (Date.today.year - 2)
      @errors << "Éco-PTZ : logement doit être achevé depuis ≥ 2 ans"
      return
    end

    nb_gestes = travaux_prevus.size
    return if nb_gestes == 0

    if eligible_parcours_accompagne? && sortie_passoire?
      montant = ECO_PTZ_RENO_GLOBALE
      basis   = "Rénovation globale (parcours accompagné + sortie passoire) — gain ≥ 35 % présumé"
    else
      montant = ECO_PTZ_GRILLE[[nb_gestes, 3].min] || ECO_PTZ_GRILLE[1]
      basis   = "#{nb_gestes} poste(s) de travaux"
    end

    @financement << {
      slug:        rule.slug,
      name:        rule.name,
      type:        "eco_ptz",
      nature:      :pret,
      amount:      montant,
      basis:       basis,
      source:      rule.source_label,
      valid_until: rule.valid_until,
      confidence:  :high,
      note:        "Prêt remboursable, sans intérêts. Durée max 20 ans. Sans condition de revenus."
    }
  end

  # ================================================================
  # Grand Nancy — Isolation (inchangé)
  # ================================================================
  def calculate_grand_nancy_isolation
    return unless territory_grand_nancy?
    return unless maison_individuelle?
    rule = AidRule.find_by(slug: "grand_nancy_isolation", active: true)
    return unless rule

    return if eligible_parcours_accompagne?

    dpe_cible = @p.dpe_target&.upcase
    unless %w[A B C].include?(dpe_cible)
      @errors << "Grand Nancy Isolation : cible DPE doit être ≥ C (actuelle cible : #{dpe_cible || '?'})"
      return
    end

    grille = modeste_ou_tres_modeste? ? GN_ISOLATION_MODESTE : GN_ISOLATION_SUPERIEUR

    total  = 0
    detail = []

    {
      "ite"              => surface_poste("ite"),
      "iti"              => surface_poste("iti"),
      "sarking"          => surface_poste("sarking"),
      "combles_perdus"   => surface_poste("combles_perdus"),
      "toiture_terrasse" => surface_poste("toiture_terrasse"),
      "plancher_bas"     => surface_poste("plancher_bas")
    }.each do |poste, surface|
      next if surface <= 0
      taux_m2 = grille[poste]
      montant = surface * taux_m2
      total  += montant
      detail << "#{poste.upcase} #{surface.to_i} m² × #{taux_m2} € = #{montant.to_i} €"
    end

    return if total == 0

    @subventions << {
      slug:        rule.slug,
      name:        rule.name,
      type:        "local",
      nature:      :subvention,
      amount:      total.round,
      basis:       detail.join(" | "),
      source:      rule.source_label,
      valid_until: Date.new(2029, 12, 31),
      confidence:  :medium,
      note:        "Cumulable avec CEE Primes énergie Grand Nancy uniquement."
    }
  end

  # ================================================================
  # Grand Nancy — Rénovation globale (inchangé)
  # ================================================================
  def calculate_grand_nancy_renovation_globale
    return unless territory_grand_nancy?
    return unless maison_individuelle?
    return unless eligible_parcours_accompagne?
    return unless @p.income_bracket.present?

    rule = AidRule.find_by(slug: "grand_nancy_renovation_globale", active: true)
    return unless rule

    config  = GN_RENO_GLOBALE_TAUX[@p.income_bracket]
    return unless config

    dpe_cible  = @p.dpe_target&.upcase
    dpe_actuel = @p.dpe_class&.upcase

    # Si la cible actuelle n'est pas A ou B, on émet l'aide en "potentielle"
    # pour que l'utilisateur sache qu'elle existe et l'incite à viser plus haut.
    unless %w[A B].include?(dpe_cible)
      est_passoire_si_ab = %w[F G].include?(dpe_actuel)
      taux    = est_passoire_si_ab ? config[:taux_ab_passoire] : config[:taux_ab]
      plafond = config[:plafond]
      base    = estimated_cost_ht
      montant_si_ab = [(base * taux).round, plafond].min

      @aides_potentielles << {
        slug:        rule.slug,
        name:        rule.name,
        type:        "local",
        nature:      :subvention,
        amount:      montant_si_ab,
        basis:       "Débloquée si vous visez un DPE A ou B",
        source:      rule.source_label,
        valid_until: Date.new(2029, 12, 31),
        confidence:  :medium,
        note:        "Dispositif Métropole Grand Nancy. Pour y accéder, glissez la jauge DPE sur A ou B dans la card Rénovation énergétique."
      }
      return
    end

    # Cas standard : dpe_target = A ou B, l'aide est activée
    est_passoire = %w[F G].include?(dpe_actuel)
    taux    = est_passoire ? config[:taux_ab_passoire] : config[:taux_ab]
    plafond = config[:plafond]

    base    = estimated_cost_ht
    montant = [(base * taux).round, plafond].min

    @subventions << {
      slug:        rule.slug,
      name:        rule.name,
      type:        "local",
      nature:      :subvention,
      amount:      montant,
      basis:       "#{(taux * 100).to_i} % des dépenses HT (plafond #{plafond.to_i} €) — cible #{dpe_cible}#{est_passoire ? ' + sortie passoire' : ''}",
      source:      rule.source_label,
      valid_until: Date.new(2029, 12, 31),
      confidence:  :medium,
      note:        "Subordonné à la perception de MaPrimeRénov'. Contact ALEC Nancy obligatoire avant travaux."
    }
  end

  # ================================================================
  # Helpers
  # ================================================================

  def eligible_parcours_accompagne?
    nb_gestes   = travaux_prevus.count { |t| %w[ite iti sarking combles_perdus toiture_terrasse plancher_bas menuiseries].include?(t) }
    ventilation = travaux_prevus.include?("vmc")
    saut        = dpe_saut(@p.dpe_class&.upcase, @p.dpe_target&.upcase)
    nb_gestes >= 2 && ventilation && saut >= 2
  end

  def sortie_passoire?
    dpe_actuel = @p.dpe_class&.upcase
    dpe_cible  = @p.dpe_target&.upcase
    %w[F G].include?(dpe_actuel) && %w[A B C D].include?(dpe_cible)
  end

  def dpe_saut(actuel, cible)
    ordre = %w[A B C D E F G]
    return 0 unless actuel && cible
    (ordre.index(actuel) || 0) - (ordre.index(cible) || 0)
  end

  def territory_grand_nancy?
    GrandNancy.include?(@p.code_insee)
  end

  def maison_individuelle?
    @p.property_type.to_s.downcase == "maison"
  end

  def modeste_ou_tres_modeste?
    %w[tres_modeste modeste].include?(@p.income_bracket)
  end

  # Liste des postes de travaux réellement sélectionnés — utilisée par
  # eligible_parcours_accompagne? (filtré) et calculate_eco_ptz (taille brute).
  #
  # Dérive uniquement des champs structurés de la propriété :
  #   - colonnes surface_* > 0 → postes d'isolation correspondants ;
  #   - vmc_double_flux true → "vmc" ;
  #   - nb_parois_vitrees > 0 → "menuiseries" ;
  #   - au moins un équipement chauffage coché → macro "chauffage" ;
  #   - au moins un équipement chauffe-eau coché → macro "chauffe_eau".
  #
  # Plus de parse de description, plus de fallback F/G qui fabriquait
  # ["ite", "vmc"] artificiellement (et surévaluait l'éco-PTZ à 2 postes).
  def travaux_prevus
    travaux = []

    travaux << "ite"              if surface_poste("ite") > 0
    travaux << "iti"              if surface_poste("iti") > 0
    travaux << "sarking"          if surface_poste("sarking") > 0
    travaux << "combles_perdus"   if surface_poste("combles_perdus") > 0
    travaux << "toiture_terrasse" if surface_poste("toiture_terrasse") > 0
    travaux << "plancher_bas"     if surface_poste("plancher_bas") > 0

    travaux << "vmc"              if truthy?(@p.vmc_double_flux)
    travaux << "menuiseries"      if @p.nb_parois_vitrees.to_i > 0

    # Macros chauffage / chauffe-eau : un seul poste par macro, peu importe
    # combien d'équipements sont cochés à l'intérieur (un poste éco-PTZ =
    # un type de travaux). On réutilise le mapping macro→équipements du
    # mapper pour rester en cohérence avec MPR Par geste / CEE.
    if TravauxMapperService::MACRO_TO_EQUIPEMENTS["chauffage"].any? { |code| truthy?(@p.send(code)) }
      travaux << "chauffage"
    end
    if TravauxMapperService::MACRO_TO_EQUIPEMENTS["chauffe_eau"].any? { |code| truthy?(@p.send(code)) }
      travaux << "chauffe_eau"
    end

    # Filtre final : si un filtre macro est actif, ne garder que les
    # postes dont le macro parent est coché. POSTE_TO_MACRO ne contient
    # pas "chauffage"/"chauffe_eau" (ce sont déjà des macros) : on les
    # mappe à eux-mêmes.
    if @travaux_actifs
      travaux = travaux.select do |poste|
        macro = TravauxMapperService::POSTE_TO_MACRO[poste] || poste
        @travaux_actifs.include?(macro)
      end
    end

    travaux.uniq
  end

  # Liste STRUCTURÉE des travaux : hash { poste_code => { quantite:, unite: } }.
  # Utilisée par MPR Par geste et CEE. Lit les colonnes surface_* + equipements_selection.
  # Chaque entrée a :quantite (m², nombre ou 1 pour un booléen) et :unite (libellé).
  def structured_travaux
    travaux = {}

    # ---- Surfaces d'isolation (colonnes decimal sur Property) ----
    # ITE / ITI / sarking / combles perdus / toiture terrasse / plancher bas
    # sont tracés séparément pour les aides locales Grand Nancy,
    # mais pour MPR Par geste on les mappe sur les 2 forfaits MPR :
    #   - surface_rampants  (= rampants + combles aménagés + sarking)
    #   - surface_toiture_terrasse
    #
    # On passe par surface_poste() pour que le filtre travaux_actifs
    # (via surface_active?) s'applique automatiquement aux 6 postes.
    surface_rampants = [
      surface_poste("sarking"),        # sarking = isolation toiture par l'extérieur
      surface_poste("combles_perdus")  # plancher des combles perdus
    ].sum

    if surface_rampants > 0
      travaux["surface_rampants"] = { quantite: surface_rampants, unite: "m²" }
    end

    if surface_poste("toiture_terrasse") > 0
      travaux["surface_toiture_terrasse"] = { quantite: surface_poste("toiture_terrasse"), unite: "m²" }
    end

    # ITE / ITI : éligibles au CEE (opérations BAR-EN-102 et BAR-EN-101)
    # mais PAS à MPR Par geste (la grille MPR ne couvre que rampants et
    # toiture terrasse côté isolation). On les liste ici : le côté CEE
    # les compte via CEE_FORFAITS, le côté MPR Par geste les ignore
    # automatiquement faute d'entrée dans MPR_PAR_GESTE_FORFAITS.
    if surface_poste("ite") > 0
      travaux["surface_ite"] = { quantite: surface_poste("ite"), unite: "m²" }
    end

    if surface_poste("iti") > 0
      travaux["surface_iti"] = { quantite: surface_poste("iti"), unite: "m²" }
    end

    # Plancher bas : pas encore modélisé côté CEE (BAR-EN-103) ni MPR
    # par-geste. Listé uniquement pour Grand Nancy Isolation via les
    # surfaces directes.

    # ---- Équipements (booléens / compteurs dans equipements_selection jsonb) ----
    # Si @travaux_actifs est défini, seuls les équipements rattachés à un
    # macro-poste coché sont inclus. Voir TravauxMapperService::MACRO_TO_EQUIPEMENTS.
    %w[
      pac_air_eau pac_geothermique
      chauffe_eau_thermo chauffe_eau_solaire
      systeme_solaire_combine pvt_eau
      poele_buches poele_granules insert_foyer
      raccordement_reseau_chaleur depose_fioul
      vmc_double_flux audit_energetique
    ].each do |code|
      next unless truthy?(@p.send(code))
      next unless equipement_actif?(code)
      travaux[code] = { quantite: 1, unite: "unité" }
    end

    # Nombre de fenêtres simple → double vitrage
    # Filtré par la macro "menuiseries" via equipement_actif?.
    nb = @p.nb_parois_vitrees.to_i
    if nb > 0 && equipement_actif?("nb_parois_vitrees")
      travaux["nb_parois_vitrees"] = { quantite: nb, unite: "équip." }
    end

    travaux
  end

  # Base HT utilisée par MPR Ampleur ET Grand Nancy Rénovation Globale
  def estimated_cost_ht
    if @p.respond_to?(:device_simulation) && @p.device_simulation&.total_aid_estimate
      (@p.device_simulation.total_aid_estimate * 1.8 / 1.10).round
    elsif @p.analysis&.content.present?
      parsed = JSON.parse(@p.analysis.content) rescue nil
      budget_max = parsed&.dig("energie", "travaux")&.sum { |t| t["cout_max"].to_i } || 0
      budget_max > 0 ? (budget_max / 1.10).round : (@p.surface.to_f * 600 / 1.10).round
    else
      (@p.surface.to_f * 600 / 1.10).round
    end
  end

  # Budget TTC estimé (utilisé pour appliquer les caps cumul)
  def estimated_budget_ttc
    if @p.analysis&.content.present?
      parsed = JSON.parse(@p.analysis.content) rescue nil
      bmax = parsed&.dig("energie", "travaux")&.sum { |t| t["cout_max"].to_i } || 0
      return bmax if bmax > 0
    end
    (@p.surface.to_f * 600).round
  end

  # Surface d'un poste d'isolation (ite, iti, sarking, combles_perdus,
  # toiture_terrasse, plancher_bas). Lit la colonne decimal correspondante
  # sur Property.
  #
  # Si un filtre macro-postes est actif (@travaux_actifs non nil), la
  # surface est retournée comme 0.0 quand son macro-poste parent n'est
  # pas dans la liste des cases cochées — ce qui neutralise la surface
  # dans les calculs MPR Par geste et Grand Nancy Isolation.
  def surface_poste(poste)
    return 0.0 unless surface_active?(poste.to_s)
    col = "surface_#{poste}"
    @p.respond_to?(col) ? @p.send(col).to_f : 0.0
  end

  # Un poste de surface (ite, sarking, etc.) est-il autorisé par le
  # filtre travaux_actifs ? Renvoie true sans filtre actif.
  def surface_active?(poste)
    return true if @travaux_actifs.nil?
    macro = TravauxMapperService::POSTE_TO_MACRO[poste]
    macro && @travaux_actifs.include?(macro)
  end

  # Un équipement booléen (pac_air_eau, chauffe_eau_thermo, etc.)
  # est-il autorisé par le filtre travaux_actifs ? Renvoie true
  # sans filtre actif.
  def equipement_actif?(code)
    return true if @travaux_actifs.nil?
    @equipements_autorises ||= TravauxMapperService.equipements_for(@travaux_actifs)
    @equipements_autorises.include?(code.to_s)
  end

  # store_accessor retourne "true" / "false" / true / false / nil selon les cas
  def truthy?(val)
    return false if val.nil?
    return val if [true, false].include?(val)
    %w[true 1 yes oui].include?(val.to_s.downcase.strip)
  end

  def format_quantite(qty, unite)
    case unite
    when "m²"     then "#{qty.to_i} m²"
    when "équip." then "#{qty.to_i} éq."
    else               qty.to_i.to_s
    end
  end
end

