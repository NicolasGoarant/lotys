# app/services/aid_calculator_service.rb
#
# Calcule les aides éligibles pour une propriété donnée.
# Sources :
#   - MaPrimeRénov' : ANAH / economie.gouv.fr (règles 2026, ouverture 23/02/2026)
#   - Éco-PTZ       : service-public.fr / effy.fr (grille complète 2026)
#   - Grand Nancy   : Règlement d'intervention maisons individuelles (délibération 06/06/2024,
#                     en vigueur 01/10/2024, valable jusqu'au 31/12/2029)
#
# IMPORTANT : L'éco-PTZ est un PRÊT, pas une subvention.
# Il est retourné dans [:financement], jamais dans [:total_subventions].
#
# Usage :
#   result = AidCalculatorService.new(property).call
#   result[:total_subventions]   # => 18_500.0  (MPR + Grand Nancy uniquement)
#   result[:subventions]         # => [{ name: "MaPrimeRénov'...", amount: 16000, ... }]
#   result[:financement]         # => [{ name: "Éco-PTZ", amount: 30000, nature: :pret, ... }]
#   result[:errors]              # => ["..."]

class AidCalculatorService

  # ----------------------------------------------------------------
  # Taux MPR 2026 (parcours accompagné)
  # Source : economie.gouv.fr / VELUX / Hellio — réouverture 23/02/2026
  # ----------------------------------------------------------------
  MPR_TAUX_2026 = {
    "tres_modeste"  => 0.80,
    "modeste"       => 0.60,
    "intermediaire" => 0.45,
    "superieur"     => 0.10
  }.freeze

  # Plafonds de dépenses HT éligibles selon le saut de classes DPE
  # (abaissés depuis sept. 2025, confirmés pour 2026)
  MPR_PLAFOND_TRAVAUX_HT = {
    2 => 30_000,   # saut de 2 classes
    3 => 40_000,   # saut de 3 classes
    4 => 40_000    # saut de 4 classes ou + (plafond 70k supprimé)
  }.freeze

  # ----------------------------------------------------------------
  # Grille Éco-PTZ 2026
  # Source : effy.fr, service-public.fr
  # ----------------------------------------------------------------
  ECO_PTZ_GRILLE = {
    1 => 15_000,   # 1 poste de travaux
    2 => 25_000,   # 2 postes
    3 => 30_000    # 3 postes ou +
    # 50 000 € si gain énergétique ≥ 35% ET sortie passoire → calculé séparément
  }.freeze
  ECO_PTZ_RENO_GLOBALE = 50_000  # parcours accompagné avec gain ≥ 35%

  # ----------------------------------------------------------------
  # Grand Nancy — aide isolation (€/m²)
  # Source : Règlement d'intervention maisons individuelles, Art. 3, p.6
  # Valable : 01/10/2024 → 31/12/2029
  # ----------------------------------------------------------------
  GN_ISOLATION_MODESTE = {
    "ite"             => 40,   # murs par l'extérieur
    "iti"             => 10,   # murs par l'intérieur
    "sarking"         => 50,   # toiture par l'extérieur (combles aménagés)
    "combles_perdus"  => 10,
    "toiture_terrasse"=> 40,
    "plancher_bas"    => 15
  }.freeze

  GN_ISOLATION_SUPERIEUR = {
    "ite"             => 30,
    "iti"             =>  5,
    "sarking"         => 40,
    "combles_perdus"  =>  5,
    "toiture_terrasse"=> 30,
    "plancher_bas"    => 10
  }.freeze

  # Grand Nancy — aide rénovation globale (% dépenses MPR, cible A/B)
  # Source : Règlement d'intervention maisons individuelles, Art. 3, p.5
  GN_RENO_GLOBALE_TAUX = {
    "tres_modeste"  => { taux_ab: 0.25, taux_ab_passoire: 0.15, plafond: 10_000 },
    "modeste"       => { taux_ab: 0.25, taux_ab_passoire: 0.15, plafond:  7_500 },
    "intermediaire" => { taux_ab: 0.15, taux_ab_passoire: 0.05, plafond:  5_000 },
    "superieur"     => { taux_ab: 0.15, taux_ab_passoire: 0.05, plafond:  2_500 }
  }.freeze

  def initialize(property)
    @p           = property
    @subventions = []
    @financement = []
    @errors      = []
  end

  def call
    calculate_mpr
    calculate_eco_ptz
    calculate_grand_nancy_isolation
    calculate_grand_nancy_renovation_globale

    {
      subventions:        @subventions,
      financement:        @financement,
      total_subventions:  @subventions.sum { |a| a[:amount] },
      errors:             @errors,
      calculated_at:      Time.current
    }
  end

  private

  # ================================================================
  # 1. MaPrimeRénov' — Parcours accompagné (rénovation d'ampleur)
  # ================================================================
  # Conditions 2026 :
  #   - DPE actuel E, F ou G (obligatoire depuis réouverture 23/02/2026)
  #   - Logement construit depuis ≥ 15 ans
  #   - Résidence principale
  #   - ≥ 2 gestes d'isolation + ventilation traitée
  #   - Gain ≥ 2 classes DPE
  #   - Accompagnateur Rénov' obligatoire
  #   - Taux : 80/60/45/10% selon revenus
  #   - Plafond travaux HT : 30k€ (saut 2-3 classes) ou 40k€ (saut 3+)
  #   - Bonus sortie passoire SUPPRIMÉ depuis sept. 2025
  # ================================================================
  def calculate_mpr
    rule = AidRule.find_by(slug: "mpr_parcours_accompagne", active: true)
    return unless rule

    unless @p.income_bracket.present?
      @errors << "Revenus non renseignés — MaPrimeRénov' non calculable"
      return
    end

    # Condition DPE actuel E/F/G obligatoire en 2026
    dpe_actuel = @p.dpe_class&.upcase
    unless %w[E F G].include?(dpe_actuel)
      @errors << "MPR Rénovation d'ampleur réservée aux logements E, F ou G (DPE actuel : #{dpe_actuel || '?'})"
      return
    end

    # Condition ancienneté ≥ 15 ans
    if @p.construction_year.present? && @p.construction_year.to_i > (Date.today.year - 15)
      @errors << "MPR : logement doit avoir ≥ 15 ans (construit en #{@p.construction_year})"
      return
    end

    unless eligible_parcours_accompagne?
      @errors << "Non éligible parcours accompagné (requis : ≥ 2 gestes isolation + ventilation + saut ≥ 2 classes DPE)"
      return
    end

    taux    = MPR_TAUX_2026[@p.income_bracket] || 0
    saut    = dpe_saut(@p.dpe_class&.upcase, @p.dpe_target&.upcase)
    plafond_ht = MPR_PLAFOND_TRAVAUX_HT[[saut, 4].min] || MPR_PLAFOND_TRAVAUX_HT[2]
    base_ht = [estimated_cost_ht, plafond_ht].min
    montant = (base_ht * taux).round

    # Pas de bonus sortie passoire en 2026 (supprimé depuis sept. 2025)

    @subventions << {
      slug:        rule.slug,
      name:        rule.name,
      type:        "mpr",
      nature:      :subvention,
      amount:      montant,
      basis:       "#{(taux * 100).to_i}% × #{base_ht.to_i} € HT (plafond #{plafond_ht.to_i} € HT, saut #{saut} classes)",
      source:      rule.source_label,
      valid_until: rule.valid_until,
      confidence:  :medium
    }
  end

  # ================================================================
  # 2. Éco-PTZ — Prêt à taux zéro (FINANCEMENT, pas subvention)
  # ================================================================
  # Grille 2026 :
  #   1 poste : 15 000 €
  #   2 postes : 25 000 €
  #   3 postes + : 30 000 €
  #   Réno globale (gain ≥ 35%, sortie passoire) : 50 000 €
  # Conditions :
  #   - Logement achevé depuis ≥ 2 ans
  #   - Résidence principale
  #   - Artisan RGE
  #   - Pas de condition de revenus
  # ================================================================
  def calculate_eco_ptz
    rule = AidRule.find_by(slug: "eco_ptz", active: true)
    return unless rule

    # Condition ancienneté ≥ 2 ans (plus restrictif : ≥ 15 ans pour MPR, mais éco-PTZ = 2 ans)
    if @p.construction_year.present? && @p.construction_year.to_i > (Date.today.year - 2)
      @errors << "Éco-PTZ : logement doit être achevé depuis ≥ 2 ans"
      return
    end

    nb_gestes = travaux_prevus.size
    return if nb_gestes == 0

    if eligible_parcours_accompagne? && sortie_passoire?
      # Rénovation globale avec gain ≥ 35% présumé si parcours accompagné + sortie passoire
      montant = ECO_PTZ_RENO_GLOBALE
      basis   = "Rénovation globale (parcours accompagné + sortie passoire) — gain ≥ 35% présumé"
    else
      montant = ECO_PTZ_GRILLE[[nb_gestes, 3].min] || ECO_PTZ_GRILLE[1]
      basis   = "#{nb_gestes} poste(s) de travaux"
    end

    # L'éco-PTZ va dans :financement, pas :subventions
    @financement << {
      slug:        rule.slug,
      name:        rule.name,
      type:        "eco_ptz",
      nature:      :pret,                  # ← PRÊT REMBOURSABLE
      amount:      montant,
      basis:       basis,
      source:      rule.source_label,
      valid_until: rule.valid_until,
      confidence:  :high,
      note:        "Prêt remboursable, sans intérêts. Durée max 20 ans. Sans condition de revenus."
    }
  end

  # ================================================================
  # 3. Grand Nancy — Aide aux travaux d'ISOLATION (€/m²)
  # ================================================================
  # Pour les projets NE rentrant PAS dans MPR parcours accompagné.
  # Cible : étiquette C minimum après travaux.
  # Maisons individuelles uniquement, résidence principale, ≥ 15 ans.
  # Source : Règlement d'intervention, Art. 3 "Aides aux travaux d'isolation"
  # ================================================================
  def calculate_grand_nancy_isolation
    return unless territory_grand_nancy?
    return unless maison_individuelle?
    rule = AidRule.find_by(slug: "grand_nancy_isolation", active: true)
    return unless rule

    # Ce dispositif est pour ceux qui NE font PAS le parcours accompagné MPR
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
      "ite"             => surface_poste("ite"),
      "iti"             => surface_poste("iti"),
      "sarking"         => surface_poste("sarking"),
      "combles_perdus"  => surface_poste("combles_perdus"),
      "toiture_terrasse"=> surface_poste("toiture_terrasse"),
      "plancher_bas"    => surface_poste("plancher_bas")
    }.each do |poste, surface|
      next if surface <= 0
      taux_m2 = grille[poste]
      montant  = surface * taux_m2
      total   += montant
      detail  << "#{poste.upcase} #{surface.to_i}m² × #{taux_m2}€ = #{montant.to_i}€"
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
      note:        "Cumulable avec CEE Primes énergie Grand Nancy uniquement (pas les CEE fournisseurs)."
    }
  end

  # ================================================================
  # 4. Grand Nancy — Aide à la RÉNOVATION GLOBALE (% dépenses MPR)
  # ================================================================
  # Pour les projets s'inscrivant dans MPR parcours accompagné.
  # Cible : étiquette A ou B (≤ 110 kWhEP/m².an).
  # Maisons individuelles uniquement, résidence principale, ≥ 15 ans.
  # L'intervention Grand Nancy est subordonnée à la perception de MPR.
  # NON cumulable avec l'aide isolation Grand Nancy.
  # Source : Règlement d'intervention, Art. 3 "Aides aux travaux de rénovation globale"
  # ================================================================
  def calculate_grand_nancy_renovation_globale
    return unless territory_grand_nancy?
    return unless maison_individuelle?
    return unless eligible_parcours_accompagne?
    return unless @p.income_bracket.present?

    rule = AidRule.find_by(slug: "grand_nancy_renovation_globale", active: true)
    return unless rule

    dpe_cible = @p.dpe_target&.upcase
    unless %w[A B].include?(dpe_cible)
      # Dispositif uniquement pour cible A ou B
      return
    end

    config  = GN_RENO_GLOBALE_TAUX[@p.income_bracket]
    return unless config

    # Taux selon sortie de passoire ou non
    dpe_actuel = @p.dpe_class&.upcase
    est_passoire = %w[F G].include?(dpe_actuel)
    taux    = est_passoire ? config[:taux_ab_passoire] : config[:taux_ab]
    plafond = config[:plafond]

    base    = estimated_cost_ht  # même base que MPR
    montant = [(base * taux).round, plafond].min

    @subventions << {
      slug:        rule.slug,
      name:        rule.name,
      type:        "local",
      nature:      :subvention,
      amount:      montant,
      basis:       "#{(taux * 100).to_i}% des dépenses HT (plafond #{plafond.to_i} €) — cible #{dpe_cible}#{est_passoire ? ' + sortie passoire' : ''}",
      source:      rule.source_label,
      valid_until: Date.new(2029, 12, 31),
      confidence:  :medium,
      note:        "Subordonné à la perception de MaPrimeRénov'. Nécessite contact ALEC Nancy avant travaux."
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
    cp = @p.zipcode.to_s
    grand_nancy_zipcodes = %w[
      54000 54100 54200 54300 54500 54510 54520
      54600 54700 54710 54140 54180 54230 54340 54400
    ]
    grand_nancy_zipcodes.include?(cp)
  end

  def maison_individuelle?
    @p.property_type.to_s.downcase == "maison"
  end

  def modeste_ou_tres_modeste?
    %w[tres_modeste modeste].include?(@p.income_bracket)
  end

  def travaux_prevus
    travaux = []
    desc = @p.description.to_s.downcase

    travaux << "ite"              if desc.include?("ite") || desc.include?("extérieur") || surface_poste("ite") > 0
    travaux << "iti"              if desc.include?("iti") || (desc.include?("intérieur") && desc.include?("isol")) || surface_poste("iti") > 0
    travaux << "sarking"          if desc.include?("sarking") || surface_poste("sarking") > 0
    travaux << "combles_perdus"   if desc.include?("combles perdus") || surface_poste("combles_perdus") > 0
    travaux << "toiture_terrasse" if desc.include?("toiture terrasse") || surface_poste("toiture_terrasse") > 0
    travaux << "plancher_bas"     if desc.include?("plancher") || desc.include?("dalle") || surface_poste("plancher_bas") > 0
    travaux << "vmc"              if desc.include?("vmc") || desc.include?("ventilation")
    travaux << "menuiseries"      if desc.include?("fenêtre") || desc.include?("menuiserie")

    # Fallback DPE F/G sans travaux détectés
    dpe = @p.dpe_class&.upcase
    if travaux.empty? && %w[F G].include?(dpe)
      travaux = ["ite", "vmc"]
    end

    travaux.uniq
  end

  def estimated_cost_ht
    if @p.respond_to?(:device_simulation) && @p.device_simulation&.total_aid_estimate
      (@p.device_simulation.total_aid_estimate * 1.8 / 1.10).round
    else
      (@p.surface.to_f * 600 / 1.10).round
    end
  end

  # Surfaces par poste — lit les colonnes dédiées si elles existent,
  # sinon retourne 0 (ne plus fallback sur les valeurs de 3 impasse du Canal)
  def surface_poste(poste)
    col = "surface_#{poste}"
    @p.respond_to?(col) ? @p.send(col).to_f : 0.0
  end
end
