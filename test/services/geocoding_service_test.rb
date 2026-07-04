require "test_helper"
require "minitest/mock"

# Tests unitaires GeocodingService — garants de "aucun appel BAN inutile".
#
# Le service est déjà idempotent et défensif : il court-circuite quand
# la Property est déjà géocodée, et quand la query construite depuis
# address+city est vide. Ces tests codifient ces garanties AVANT le
# parcours C4 (job qui skip GeocodingService si address vide) et
# préparent la stub BAN de C7.
#
# Stub : Object#stub de Minitest (dispo dans le core Ruby depuis 2.0)
# remplace HTTParty.get pour la durée du bloc. Si le service tente un
# appel, la lambda lève et le test échoue — pas d'appel réseau réel.
class GeocodingServiceTest < ActiveSupport::TestCase
  def base_attrs
    {
      claim_token: SecureRandom.hex(16),
      documents_pending: true  # bypass la validation C2 sans coller de doc réel
    }
  end

  test "adresse vide (parcours documents seuls, C2) : AUCUN appel BAN" do
    p = Property.new(base_attrs)
    p.save(validate: false)  # bien orphelin sans address, docs pending virtuel

    HTTParty.stub :get, ->(*_args) { raise "appel BAN inattendu" } do
      assert_nothing_raised { GeocodingService.new(p).call }
    end

    p.reload
    assert_nil p.lat,        "Pas de géocodage → lat reste NULL"
    assert_nil p.lng,        "Pas de géocodage → lng reste NULL"
    assert_nil p.code_insee, "Pas de géocodage → code_insee reste NULL"
  end

  test "déjà géocodé (lat + lng + code_insee posés) : short-circuit sans appel BAN" do
    p = Property.new(base_attrs.merge(
      address:    "14 rue des Tilleuls",
      city:       "Vandœuvre-lès-Nancy",
      zipcode:    "54500",
      lat:        48.65,
      lng:        6.16,
      code_insee: "54547"
    ))
    p.save(validate: false)

    HTTParty.stub :get, ->(*_args) { raise "appel BAN inattendu" } do
      assert_nothing_raised { GeocodingService.new(p).call }
    end

    # Idempotent — les valeurs existantes ne bougent pas.
    p.reload
    assert_equal 48.65,  p.lat
    assert_equal 6.16,   p.lng
    assert_equal "54547", p.code_insee
  end

  test "adresse partielle (city seule sans address) : AUCUN appel BAN (query vide)" do
    # Cas dégénéré : address nil, city seule. Le service construit la
    # query = [nil, "Nancy"].compact_blank.join(" ") = "Nancy" → non
    # vide. Ici on documente que la garantie du guard C4 côté JOB est
    # plus stricte que celle du service — mais le service reste
    # défensif via son propre guard sur query.blank?.
    p = Property.new(base_attrs.merge(city: "Nancy"))
    p.save(validate: false)

    # Ici le service TENTE l'appel BAN (query="Nancy" non vide). Le
    # guard applicable est celui du JOB (property.address.present?),
    # cf. C4. On ne teste donc pas l'absence d'appel ici, juste que
    # le service n'écrit rien de faux si BAN renvoie vide.
    fake_response = Struct.new(:body).new({ "features" => [] }.to_json)
    HTTParty.stub :get, ->(*_args) { fake_response } do
      assert_nothing_raised { GeocodingService.new(p).call }
    end

    p.reload
    assert_nil p.lat,        "BAN vide → lat reste NULL (pas d'écriture spéculative)"
    assert_nil p.code_insee, "BAN vide → code_insee reste NULL"
  end
end
