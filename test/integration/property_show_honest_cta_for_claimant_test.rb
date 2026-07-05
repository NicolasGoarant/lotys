require "test_helper"
require_relative "../support/aid_rules_helper"

# Fiche du bien (properties/show) — CTA honnêtes selon l'autorité de
# l'utilisateur sur le bien.
#
# Trois profils distincts, trois règles :
#   1. OWNER (connecté et propriétaire du bien) : tous les submits sont
#      vrais — form-travaux ET form foyer fiscal fonctionnent.
#   2. CLAIMANT (a le claim_token du bien dans son cookie signé) :
#      - form-travaux : LIEN d'inscription à la place du submit
#        (update_travaux_selection reste protégé par authenticate_user!,
#        le CTA honnête est "créer un compte pour persister"),
#      - form foyer fiscal : ÉDITABLE et fonctionnel depuis la feature
#        "aides sans compte" — update_income_bracket accepte désormais
#        le claim_token (cf. set_property_for_edit_aids).
#   3. TIERS (visiteur d'un bien publié sans être owner ni claimant) :
#      les champs sensibles (RFR, household_size, tranche) sont MASQUÉS.
#      La section aides invite à créer sa propre estimation.
class PropertyShowHonestCtaForClaimantTest < ActionDispatch::IntegrationTest
  include AidRulesHelper

  CLAIM_COOKIE = ClaimToken::CLAIM_COOKIE
  GOOD_TOKEN   = "JETON_CLAIMANT_HONEST_CTA"

  SUBMIT_TRAVAUX = "Mettre à jour les aides"
  SUBMIT_AIDES   = "Calculer mes aides"  # renommé depuis "Recalculer" avec la feature aides sans compte

  RFR_INPUT_NAME       = "property[rfr]"
  HOUSEHOLD_INPUT_NAME = "property[household_size]"

  setup do
    seed_aid_rules!
  end

  # ─── E. Claimant — form-travaux reste protégé, CTA compte à la place ─
  test "E — claimant : pas de submit 'Mettre à jour les aides' dans le form-travaux, lien inscription à sa place" do
    orphan = create_orphan_property!(claim_token: GOOD_TOKEN)
    seed_full_analysis!(orphan)
    set_signed_cookie(CLAIM_COOKIE, GOOD_TOKEN)

    get property_path(orphan)
    assert_response :success

    assert_select "form#form-travaux input[type=submit][value=?]",
                  SUBMIT_TRAVAUX,
                  { count: 0 },
                  "Le submit '#{SUBMIT_TRAVAUX}' ne doit pas exister pour le claimant : " \
                  "update_travaux_selection reste protégé (le CTA honnête est le lien d'inscription)."
    assert_select "form#form-travaux a[href=?]",
                  new_user_registration_path,
                  { minimum: 1 },
                  "Lien d'inscription attendu à la place du submit travaux (piège clavier fermé pour ce form)"
  end

  # ─── F. Claimant — form foyer fiscal ÉDITABLE (aides sans compte) ────
  test "F — claimant : form foyer fiscal PRÉSENT et éditable, submit 'Calculer mes aides' actif" do
    orphan = create_orphan_property!(claim_token: GOOD_TOKEN)
    seed_full_analysis!(orphan)
    set_signed_cookie(CLAIM_COOKIE, GOOD_TOKEN)

    get property_path(orphan)
    assert_response :success

    # Le form éditable EST là — le calcul des aides est le cœur de la
    # valeur produit, il ne peut PAS être derrière un compte.
    assert_select "div#aides form[action=?][method=?]",
                  update_income_bracket_property_path(orphan),
                  "post",
                  { count: 1 },
                  "Le claimant DOIT avoir le form foyer fiscal éditable (feature aides sans compte)."
    assert_select "div#aides input[name=?]", RFR_INPUT_NAME,       { count: 1 }
    assert_select "div#aides input[name=?]", HOUSEHOLD_INPUT_NAME, { count: 1 }
    assert_select "div#aides input[type=submit][value=?]", SUBMIT_AIDES, { count: 1 }
  end

  # ─── F-bis. Claimant — le CTA compte reste, mais DÉCOUPLÉ du form ────
  test "F-bis — claimant : lien 'conserver ce dossier' présent, mais DÉCOUPLÉ du form foyer fiscal" do
    orphan = create_orphan_property!(claim_token: GOOD_TOKEN)
    seed_full_analysis!(orphan)
    set_signed_cookie(CLAIM_COOKIE, GOOD_TOKEN)

    get property_path(orphan)
    assert_response :success

    # Le CTA existe dans le bloc Aides.
    assert_select "div#aides a[href=?]",
                  new_user_registration_path,
                  { minimum: 1 },
                  "Le CTA 'conserver ce dossier' reste — la sauvegarde exige un compte"
    # Wording adapté : "conserver" (pas "calculer" — le calcul est fait par le form).
    assert_match(/conserver ce dossier/i, response.body,
      "Le nouveau wording du CTA doit refléter la sauvegarde, pas le calcul")
    refute_match(/Créer un compte pour calculer/i, response.body,
      "Anti-régression du wording 'Créer un compte pour calculer' — désormais faux (le calcul se fait sans compte)")
  end

  # ─── G. NON-RÉGRESSION OWNER — form intact + submit renommé ──────────
  test "G — owner connecté : form-travaux et form foyer fiscal INTACTS, submit foyer renommé 'Calculer mes aides'" do
    owner = create_confirmed_user!
    property = create_owned_property!(owner: owner)
    seed_full_analysis!(property)

    sign_in owner
    get property_path(property)
    assert_response :success

    assert_select "form#form-travaux input[type=submit][value=?]",
                  SUBMIT_TRAVAUX, { count: 1 }
    assert_select "div#aides input[type=submit][value=?]",
                  SUBMIT_AIDES, { count: 1 },
                  "Owner garde le submit foyer fiscal (renommé 'Calculer mes aides')"
    assert_select "form#form-travaux a[href=?]",
                  new_user_registration_path, { count: 0 },
                  "Owner ne voit JAMAIS de lien d'inscription (il est déjà inscrit)"
    assert_select "div#aides form[action=?][method=?]",
                  update_income_bracket_property_path(property), "post",
                  { count: 1 }
    assert_select "div#aides input[name=?]", RFR_INPUT_NAME,       { count: 1 }
    assert_select "div#aides input[name=?]", HOUSEHOLD_INPUT_NAME, { count: 1 }
  end

  # ─── H. Claimant PEUT POSTER update_income_bracket (autorisation) ────
  test "H — claimant : POST update_income_bracket → 302 vers show avec notice (pas de sign-in intercepté)" do
    orphan = create_orphan_property!(claim_token: GOOD_TOKEN)
    set_signed_cookie(CLAIM_COOKIE, GOOD_TOKEN)

    patch update_income_bracket_property_path(orphan),
          params: { property: { household_size: 4, rfr: 30_000 } }

    assert_redirected_to property_path(orphan, anchor: "aides"),
      "Le claimant est redirigé vers son bien — PAS interceptée par authenticate_user!"
    assert_match(/Foyer fiscal mis à jour/i, flash[:notice] || "")

    orphan.reload
    assert_equal 4,     orphan.household_size, "household_size persisté"
    assert_equal 30_000, orphan.rfr,           "RFR persisté"
    # income_bracket est dérivé au before_save du modèle — vérifie le
    # recalcul en aval.
    assert orphan.income_bracket.present?,
      "income_bracket dérivé automatiquement (before_save) — recalcul des aides opérant au prochain show"
  end

  test "H-bis — owner : POST update_income_bracket → même chemin, redirect + notice" do
    owner = create_confirmed_user!
    property = create_owned_property!(owner: owner)
    sign_in owner

    patch update_income_bracket_property_path(property),
          params: { property: { household_size: 2, rfr: 45_000 } }

    assert_redirected_to property_path(property, anchor: "aides")
    property.reload
    assert_equal 2,     property.household_size
    assert_equal 45_000, property.rfr
  end

  # ─── I. TIERS — étanchéité des données fiscales (donnée sensible) ────
  # Note produit : la section "aides personnalisées" n'est PAS rendue
  # aux tiers d'un bien publié (can_see_full_dossier gate côté vue).
  # C'est l'étanchéité principale — les montants d'aides étant modulés
  # par la tranche du propriétaire, ils révèlent indirectement son RFR.
  # Le bloc "foyer-fiscal-tiers" dans le partial est là pour le jour où
  # on affichera des aides "génériques" (feature séparée, hors périmètre).
  test "I — tiers d'un bien publié : PAS de fuite RFR/household_size/tranche" do
    owner = create_confirmed_user!
    published = create_published_property!(owner: owner)
    seed_full_analysis!(published)

    # Aucun cookie claim_token : visiteur totalement tiers.
    get property_path(published)
    assert_response :success

    # Le RFR du propriétaire (25 000 €, cf. common_rich_attrs) NE DOIT
    # PAS être visible. Anti-fuite de donnée sensible.
    refute_match(/25\s*000/, response.body,
      "Le RFR du propriétaire ne doit PAS fuir à un visiteur tiers")
    refute_match(/3\s+personnes/, response.body,
      "Le nombre de personnes du foyer ne doit PAS fuir à un tiers")
    # Aucun input éditable (le tiers ne doit rien pouvoir soumettre).
    assert_select "input[name=?]", RFR_INPUT_NAME,       { count: 0 }
    assert_select "input[name=?]", HOUSEHOLD_INPUT_NAME, { count: 0 }
    refute_match(/Tranche dérivée/, response.body,
      "La tranche dérivée révèle indirectement le RFR — ne doit pas fuir non plus")
  end

  test "I-bis — tiers : POST update_income_bracket → redirect root avec alert" do
    owner = create_confirmed_user!
    published = create_published_property!(owner: owner)

    # Pas de cookie, pas de sign_in.
    patch update_income_bracket_property_path(published),
          params: { property: { household_size: 999, rfr: 1_000_000 } }

    assert_redirected_to root_path
    published.reload
    refute_equal 999,        published.household_size, "Aucune écriture par un tiers"
    refute_equal 1_000_000,  published.rfr
  end

  # ─── Helpers ─────────────────────────────────────────────────────────

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

  def create_published_property!(owner:)
    p = owner.properties.build(
      address:              "3 rue Publiée",
      city:                 "Nancy",
      zipcode:              "54000",
      status:               :published,
      address_source:       "manuel",
      address_confirmed_at: Time.current,
      **common_rich_attrs
    )
    p.save!
    p.update!(pac_air_eau: true)
    p
  end

  def seed_full_analysis!(property)
    content = {
      "valeur"  => { "estimation_basse" => 180_000, "estimation_haute" => 220_000 },
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
