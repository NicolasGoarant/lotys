require "test_helper"

# Tests modèle Property — invariant de rattachement.
#
# Une Property doit être SOIT possédée (user_id présent), SOIT revendicable
# (claim_token présent). On vérifie les trois cas canoniques avec
# Property.new (pas de save, pas de DB) — les validations du modèle
# tournent quand même via valid?.
class PropertyTest < ActiveSupport::TestCase
  # Defaults minimaux pour passer les validations indépendantes (address,
  # city, zipcode, format zipcode). Les tests ne touchent qu'à user_id et
  # claim_token, le reste est neutralisé par ces valeurs constantes.
  def base_attrs
    {
      address: "14 rue des Tilleuls",
      city:    "Vandœuvre-lès-Nancy",
      zipcode: "54500"
    }
  end

  def build_user
    # Devise :validatable exige email + password ≥ 6 caractères. Pas de
    # save() : l'invariant rattachable se vérifie sur User en mémoire car
    # belongs_to :user, optional: true accepte un User non persisté.
    User.new(email: "test-#{SecureRandom.hex(4)}@example.com", password: "azerty123")
  end

  test "bien possédé (user présent, claim_token absent) est valide" do
    property = Property.new(base_attrs.merge(user: build_user))

    assert property.valid?,
           "Bien possédé devrait être valide, reçu errors=#{property.errors.full_messages.inspect}"
  end

  test "bien orphelin (user nil, claim_token présent) est valide" do
    property = Property.new(base_attrs.merge(user: nil, claim_token: SecureRandom.uuid))

    assert property.valid?,
           "Bien orphelin avec jeton devrait être valide, reçu errors=#{property.errors.full_messages.inspect}"
  end

  test "bien ni possédé ni revendicable (user nil, claim_token nil) est INVALIDE" do
    property = Property.new(base_attrs.merge(user: nil, claim_token: nil))

    assert_not property.valid?,
               "Bien sans user NI claim_token devrait être refusé"
    assert property.errors[:base].any? { |msg| msg.include?("rattaché") },
           "L'erreur doit porter sur :base avec un message parlant de rattachement, reçu : #{property.errors[:base].inspect}"
  end
end
