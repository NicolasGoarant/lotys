require "test_helper"
require_relative "../support/aid_rules_helper"

# Dette épistémique post-9cb37e9 : sur la fiche complète, le claimant anonyme
# voit aujourd'hui les submits "Mettre à jour les aides" et "Recalculer"
# (foyer fiscal) — mais ces submits postent vers des actions protégées par
# authenticate_user! qui le redirigent vers sign-in en jetant sa saisie.
# Le bouton SIMULE une action qui se perd : violation du principe "aucun
# chiffre/bouton bâti sur une hypothèse non faite".
#
# Règle cible : pour le claimant, à la place du submit, on rend un LIEN
# d'inscription qui dit la vérité (le compte est nécessaire pour persister).
# Pour le propriétaire connecté, RIEN ne change : ses submits marchent vraiment.
#
# Tests E/F : passe-t-on le lien d'inscription au claimant ?
# Test G : LE plus important — le propriétaire garde-t-il ses vrais submits ?
class PropertyShowHonestCtaForClaimantTest < ActionDispatch::IntegrationTest
  include AidRulesHelper

  CLAIM_COOKIE = ClaimToken::CLAIM_COOKIE
  GOOD_TOKEN   = "JETON_CLAIMANT_HONEST_CTA"

  # Libellés des submits que la promesse trompeuse porte aujourd'hui.
  SUBMIT_TRAVAUX = "Mettre à jour les aides"
  SUBMIT_RFR     = "Recalculer"

  setup do
    seed_aid_rules!
  end

  # ─── E. Claimant : lien inscription à la place du submit travaux ─────

  test "E — claimant anonyme : pas de submit 'Mettre à jour les aides' dans le form-travaux, un lien d'inscription à sa place" do
    orphan = create_orphan_property!(claim_token: GOOD_TOKEN)
    seed_full_analysis!(orphan)
    set_signed_cookie(CLAIM_COOKIE, GOOD_TOKEN)

    get property_path(orphan)
    assert_response :success

    # Le submit qui poste vers update_travaux_selection : ABSENT pour le claimant.
    # Sélecteur scopé au form-travaux pour ne pas être pollué par un éventuel
    # autre input[type=submit] de valeur identique ailleurs sur la page.
    assert_select "form#form-travaux input[type=submit][value=?]",
                  SUBMIT_TRAVAUX,
                  { count: 0 },
                  "Le submit '#{SUBMIT_TRAVAUX}' ne doit PAS exister pour le claimant : son clic est intercepté par authenticate_user! qui jette sa sélection au sign-in."

    # À la place : un lien d'inscription, encore scopé au form-travaux pour
    # ne pas confondre avec le lien d'inscription que le nav pourrait porter.
    # NB : `minimum: 1` (et pas juste un message en 3e arg) — sinon Rails
    # interprète le message comme un `equality` sur le texte du nœud.
    assert_select "form#form-travaux a[href=?]",
                  new_user_registration_path,
                  { minimum: 1 },
                  "Le claimant doit voir un lien vers #{new_user_registration_path} dans le form-travaux, à la place du submit. C'est le CTA honnête : créer un compte est la VRAIE action."
  end

  # ─── F. Claimant : lien inscription à la place du submit RFR ────────

  test "F — claimant anonyme : pas de submit 'Recalculer' du foyer fiscal dans le bloc Aides, un lien d'inscription à sa place" do
    orphan = create_orphan_property!(claim_token: GOOD_TOKEN)
    seed_full_analysis!(orphan)
    set_signed_cookie(CLAIM_COOKIE, GOOD_TOKEN)

    get property_path(orphan)
    assert_response :success

    # Le submit RFR : ABSENT pour le claimant (même piège que le submit travaux).
    # Scopé au div#aides — il n'y a pas d'autre "Recalculer" attendu dans ce bloc.
    assert_select "div#aides input[type=submit][value=?]",
                  SUBMIT_RFR,
                  { count: 0 },
                  "Le submit '#{SUBMIT_RFR}' du foyer fiscal ne doit pas exister pour le claimant : même action protégée, même perte de saisie au sign-in."

    # Lien d'inscription PRÉSENT dans le bloc Aides. `minimum: 1` car
    # plusieurs endroits du bloc Aides peuvent légitimement référer à
    # l'inscription (RFR + invitation Grand Nancy reformulée pour le claimant).
    assert_select "div#aides a[href=?]",
                  new_user_registration_path,
                  { minimum: 1 },
                  "Le claimant doit voir un lien d'inscription dans le bloc Aides à la place du submit '#{SUBMIT_RFR}'"
  end

  # ─── G. NON-RÉGRESSION OWNER (le plus important) ────────────────────

  test "G — propriétaire connecté garde les vrais submits travaux + RFR ; PAS de lien d'inscription qui les remplacerait" do
    owner = create_confirmed_user!
    property = create_owned_property!(owner: owner)
    seed_full_analysis!(property)

    sign_in owner
    get property_path(property)
    assert_response :success

    # Le propriétaire DOIT toujours avoir les deux submits — chez lui, ils
    # déclenchent un vrai POST qui persiste la sélection et recharge la fiche
    # avec @aid_result recalculé.
    assert_select "form#form-travaux input[type=submit][value=?]",
                  SUBMIT_TRAVAUX,
                  { count: 1 },
                  "Le propriétaire connecté doit GARDER le submit '#{SUBMIT_TRAVAUX}' — il marche réellement pour lui (update_travaux_selection passe). Régression si absent."
    assert_select "div#aides input[type=submit][value=?]",
                  SUBMIT_RFR,
                  { count: 1 },
                  "Le propriétaire doit garder le submit '#{SUBMIT_RFR}' du foyer fiscal — update_income_bracket marche pour lui."

    # ET aucun lien d'inscription dans ces blocs : ce serait insultant pour
    # un user déjà connecté, et trahirait qu'on confond owner et claimant.
    assert_select "form#form-travaux a[href=?]",
                  new_user_registration_path,
                  { count: 0 },
                  "Le propriétaire ne doit JAMAIS voir un lien d'inscription dans le form-travaux : il est déjà inscrit. Confondre owner et claimant = régression."
    assert_select "div#aides a[href=?]",
                  new_user_registration_path,
                  { count: 0 },
                  "Le propriétaire ne doit JAMAIS voir un lien d'inscription dans le bloc Aides."
  end

  # ─── Helpers (dupliqués localement, cohérent avec le pattern des autres
  #              tests d'intégration orphan_claim_*_test.rb) ─────────────

  private

  include Devise::Test::IntegrationHelpers

  def set_signed_cookie(name, value)
    request = ActionDispatch::TestRequest.create
    jar     = ActionDispatch::Cookies::CookieJar.build(request, cookies.to_hash)
    jar.signed[name] = value
    cookies[name.to_s] = jar[name.to_s]
  end

  def create_confirmed_user!(email: "owner-#{SecureRandom.hex(4)}@example.com")
    User.create!(
      email:                 email,
      password:              "password123",
      password_confirmation: "password123",
      confirmed_at:          Time.current
    )
  end

  # Attributs assez riches pour qu'AidCalculatorService produise du non-vide
  # (PAC + foyer modeste + maison ancienne → MPR Par geste non nul) — sinon
  # le form-travaux et les submits Aides ne seraient même pas rendus.
  def common_rich_attrs
    {
      surface:           100,
      property_type:     "maison",
      construction_year: 1970,
      dpe_class:         "F",
      dpe_target:        "C",
      household_size:    3,
      rfr:               25_000
    }
  end

  def create_orphan_property!(claim_token:)
    p = Property.new(
      address:     "14 rue des Tilleuls",
      city:        "Vandœuvre-lès-Nancy",
      zipcode:     "54500",
      claim_token: claim_token,
      status:      :analyzed,
      **common_rich_attrs
    )
    p.save!
    p.update!(pac_air_eau: true)
    p
  end

  def create_owned_property!(owner:)
    p = owner.properties.build(
      address: "2 rue Possédée",
      city:    "Nancy",
      zipcode: "54000",
      status:  :analyzed,
      **common_rich_attrs
    )
    p.save!
    p.update!(pac_air_eau: true)
    p
  end

  def seed_full_analysis!(property)
    content = {
      "valeur"  => {
        "estimation_basse" => 180_000,
        "estimation_haute" => 220_000
      },
      "energie" => {
        "dpe_estime" => "F",
        "dpe_cible"  => "C",
        "travaux"    => [
          { "poste" => "Isolation des combles", "priorite" => 1, "cout_min" => 4_000, "cout_max" => 8_000 },
          { "poste" => "Pompe à chaleur",       "priorite" => 2, "cout_min" => 10_000, "cout_max" => 15_000 }
        ]
      },
      "idees"   => { "scenarios" => [] }
    }
    Analysis.create!(property: property, content: content.to_json)
  end
end
