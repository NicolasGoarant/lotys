# Helper partagé : seed minimal des AidRule nécessaires aux services de calcul.
#
# AidCalculatorService fait `AidRule.find_by(slug: "...", active: true)` et
# retourne early si la règle est absente. Pour que les tests reflètent un
# état réaliste (calcul effectif, pas calcul à vide), on insère les règles
# canoniques en setup — même approche que le test existant
# aid_calculator_service_test.rb.
#
# La table reste vide entre runs (transactional fixtures), donc chaque test
# qui inclut ce module appelle `seed_aid_rules!` dans son setup.
module AidRulesHelper
  REQUIRED_SLUGS = %w[
    mpr_parcours_accompagne
    mpr_par_geste
    cee
    eco_ptz
    grand_nancy_isolation
    grand_nancy_renovation_globale
  ].freeze

  def seed_aid_rules!
    REQUIRED_SLUGS.each do |slug|
      AidRule.find_or_create_by(slug: slug) do |r|
        r.active       = true
        r.name         = slug.humanize
        r.source_label = "test-fixture"
        # valid_from a une contrainte NOT NULL en DB.
        r.valid_from   = Date.new(2024, 1, 1)
        r.valid_until  = Date.new(2030, 12, 31)
      end
    end
  end
end
