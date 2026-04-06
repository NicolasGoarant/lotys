class DeviceSimulationService
  ECO_PTZ_MAX = 50_000

  def initialize(property)
    @property = property
  end

  def call
    sim = @property.device_simulation || @property.build_device_simulation

    eligible_ptz  = eligible_eco_ptz?
    eligible_mpr  = eligible_maprimrenov?
    mpr_amount    = maprimrenov_amount
    cee           = estimate_cee

    sim.update(
      eligible_eco_ptz:       eligible_ptz,
      eco_ptz_max_amount:     eligible_ptz ? ECO_PTZ_MAX : 0,
      eligible_maprimrenov:   eligible_mpr,
      maprimrenov_amount:     mpr_amount,
      eligible_cee:           true,
      cee_estimated_amount:   cee,
      total_aid_estimate:     (eligible_ptz ? ECO_PTZ_MAX : 0) + mpr_amount + cee,
      notes:                  build_notes,
      simulation_data: {
        dpe_class:         @property.dpe_class,
        construction_year: @property.construction_year,
        surface:           @property.surface
      }
    )
  end

  private

  def eligible_eco_ptz?
    @property.construction_year.present? && @property.construction_year < 2023
  end

  def eligible_maprimrenov?
    %w[D E F G].include?(@property.dpe_class&.upcase)
  end

  def maprimrenov_amount
    return 0 unless eligible_maprimrenov?
    base = case @property.dpe_class&.upcase
           when "G" then 10_000
           when "F" then 8_000
           when "E" then 5_000
           else 3_000
           end
    multiplier = [(@property.surface.to_f / 70.0), 2.0].min
    (base * multiplier).round(-2)
  end

  def estimate_cee
    base = @property.surface.to_f * 15
    multiplier = %w[F G].include?(@property.dpe_class&.upcase) ? 1.5 : 1.0
    (base * multiplier).round(-2)
  end

  def build_notes
    notes = []
    notes << "DPE #{@property.dpe_class} : isolation prioritaire recommandée." if %w[F G].include?(@property.dpe_class&.upcase)
    notes << "Éco-PTZ : prêt à 0% jusqu'à 50 000€, sans condition de ressources."
    notes << "MaPrimeRénov' : demande AVANT démarrage des travaux sur anah.gouv.fr."
    notes << "CEE : négociables avec les artisans RGE ou via un agrégateur."
    notes.join(" | ")
  end
end
