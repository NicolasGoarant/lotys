class LocalAidCalculator
  BRACKETS = %i[tres_modeste modeste intermediaire superieur].freeze

  def initialize(property)
    @property = property
  end

  def call
    @property.local_aid_results.destroy_all

    LocalAidScheme.currently_valid.each do |scheme|
      compute_result(scheme)
    end

    @property.local_aid_results.reload
  end

  private

  def compute_result(scheme)
    eligible = scheme.eligible_for?(@property)

    amounts = if eligible && scheme.renov_globale?
      BRACKETS.each_with_object({}) do |bracket, h|
        val = scheme.amount_for(bracket)
        h[bracket.to_s] = val if val
      end
    else
      {}
    end

    LocalAidResult.create!(
      property:             @property,
      local_aid_scheme:     scheme,
      eligible:             eligible,
      ineligibility_reason: eligible ? nil : reason(@property, scheme),
      amounts:              amounts,
      computed_at:          Time.current
    )
  end

  def reason(property, scheme)
    return "Code postal (#{property.zipcode}) non couvert" unless scheme.covers_zipcode?(property.zipcode)
    return "Type de bien non éligible (#{property.property_type})" unless scheme.covers_property_type?(property.property_type)
    nil
  end
end
