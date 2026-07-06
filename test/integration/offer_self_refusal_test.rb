require "test_helper"

# Défense en profondeur : POST /properties/:pid/offers refuse toute
# soumission dont l'auteur est le porteur du bien — au sens propriétaire
# connecté OU au sens claim_token en cookie (porteur du parcours anonyme
# encore non rattaché à un compte).
#
# Contexte : le bloc "Faire une proposition" est aussi rendu dans le
# mode preview de la fiche (properties#preview). L'UI le rend inerte
# côté DOM (fieldset disabled), mais on ne compte pas sur le DOM pour
# la sécurité — le controller doit refuser aussi côté serveur.
class OfferSelfRefusalTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  CLAIM_COOKIE = ClaimToken::CLAIM_COOKIE

  setup do
    @owner = User.create!(
      email:                 "owner-#{SecureRandom.hex(4)}@example.com",
      password:              "password123",
      password_confirmation: "password123",
      confirmed_at:          Time.current
    )
    @property = @owner.properties.create!(
      address:              "10 rue du Test",
      city:                 "Nancy",
      zipcode:              "54000",
      surface:              90,
      property_type:        "appartement",
      construction_year:    1975,
      dpe_class:            "E",
      dpe_target:           "C",
      status:               :published,
      address_source:       "manuel",
      address_confirmed_at: Time.current
    )
    @good_offer = { offer_type: "renovation", amount: 12_000, description: "Devis" }
  end

  # ── Cas 1 : owner connecté (avec rôle prestataire) → refus ─────────

  test "POST offer par l'owner (même en rôle prestataire) → refus, aucune Offer créée" do
    # On donne à l'owner le rôle prestataire pour qu'il passe
    # require_prestataire — c'est LE cas où seul le check
    # "porteur du bien" bloque.
    @owner.update!(role: :prestataire)
    sign_in @owner

    assert_no_difference "Offer.count" do
      post property_offers_path(@property), params: { offer: @good_offer }
    end
    assert_response :redirect
    assert_equal "Vous ne pouvez pas faire une offre sur votre propre bien.",
                 flash[:alert]
  end

  # ── Cas 2 : navigateur porteur du claim_token → refus ──────────────

  test "POST offer par un prestataire dont le navigateur porte le claim_token du bien → refus" do
    # Scénario défense-en-profondeur : le bien porte encore un
    # claim_token (n'a pas été vidé par le rattachement), et le
    # navigateur d'un prestataire connecté a ce même jeton dans son
    # cookie signé. Sans ce garde-fou, il pourrait "s'auto-offrir".
    token = "TOKEN_PORTEUR_#{SecureRandom.hex(6)}"
    @property.update_column(:claim_token, token)

    prestataire = User.create!(
      email:                 "prest-#{SecureRandom.hex(4)}@example.com",
      password:              "password123",
      password_confirmation: "password123",
      role:                  :prestataire,
      confirmed_at:          Time.current
    )
    sign_in prestataire
    set_signed_cookie(CLAIM_COOKIE, token)

    assert_no_difference "Offer.count" do
      post property_offers_path(@property), params: { offer: @good_offer }
    end
    assert_response :redirect
    assert_equal "Vous ne pouvez pas faire une offre sur votre propre bien.",
                 flash[:alert]
  end

  # ── Cas 3 : vrai prestataire tiers → autorisé (non-régression) ────

  test "POST offer par un prestataire tiers SANS cookie de claim → autorisé, une Offer créée" do
    prestataire = User.create!(
      email:                 "artisan-#{SecureRandom.hex(4)}@example.com",
      password:              "password123",
      password_confirmation: "password123",
      role:                  :prestataire,
      confirmed_at:          Time.current
    )
    sign_in prestataire

    assert_difference "Offer.count", +1 do
      post property_offers_path(@property), params: { offer: @good_offer }
    end
    assert_redirected_to offers_path
    offer = Offer.order(:created_at).last
    assert_equal prestataire.id, offer.user_id
    assert_equal @property.id,   offer.property_id
  end

  # ── Cas 4 : owner en rôle propriétaire → refus (comportement historique) ─

  test "POST offer par l'owner en rôle propriétaire → refus (require_prestataire)" do
    sign_in @owner  # @owner est proprietaire par défaut

    assert_no_difference "Offer.count" do
      post property_offers_path(@property), params: { offer: @good_offer }
    end
    assert_response :redirect
    # require_prestataire s'exécute AVANT set_property_for_offer,
    # donc le message est celui du filtre rôle, pas celui du porteur.
    assert_equal "Seuls les prestataires peuvent faire une offre.",
                 flash[:alert]
  end

  private

  def set_signed_cookie(name, value)
    request = ActionDispatch::TestRequest.create
    jar     = ActionDispatch::Cookies::CookieJar.build(request, cookies.to_hash)
    jar.signed[name] = value
    cookies[name.to_s] = jar[name.to_s]
  end
end
