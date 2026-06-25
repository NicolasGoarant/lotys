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

  # Champs du form foyer fiscal — leur présence DOM côté claimant
  # signalerait la persistance du piège clavier RFR (touche Entrée → POST →
  # sign-in → saisie perdue).
  RFR_INPUT_NAME       = "property[rfr]"
  HOUSEHOLD_INPUT_NAME = "property[household_size]"

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

  test "G — propriétaire connecté garde les vrais submits travaux + RFR ; PAS de lien d'inscription qui les remplacerait ; form foyer fiscal éditable INTACT" do
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

    # ─── Extension G-rfr : le form foyer fiscal éditable est PRÉSENT
    #     et INTACT pour le propriétaire. C'est le garde-fou contre une
    #     régression du fix lecture-seule claimant qui aurait par erreur
    #     supprimé le form pour tout le monde.
    assert_select "div#aides form[action=?][method=?]",
                  update_income_bracket_property_path(property),
                  "post",
                  { count: 1 },
                  "Le propriétaire connecté doit garder son form foyer fiscal qui poste vers update_income_bracket (method:patch sort en method=post + hidden _method=patch). Régression si absent."
    assert_select "div#aides input[name=?]",
                  RFR_INPUT_NAME,
                  { count: 1 },
                  "Le propriétaire doit garder son input RFR éditable (#{RFR_INPUT_NAME})."
    assert_select "div#aides input[name=?]",
                  HOUSEHOLD_INPUT_NAME,
                  { count: 1 },
                  "Le propriétaire doit garder son input nombre de personnes éditable (#{HOUSEHOLD_INPUT_NAME})."
  end

  # ─── H. Claimant : foyer fiscal en LECTURE SEULE — piège clavier fermé ─
  #
  # Avant ce fix : le claimant voit un <form action=update_income_bracket>
  # avec un input RFR. Si l'utilisateur tape RFR puis appuie sur Entrée,
  # le browser HTML5 par défaut soumet le form → authenticate_user! le
  # redirige vers sign-in → sa saisie est perdue (Devise ne rejoue pas
  # le body POST après login). Le bouton visible était déjà honnête (lien
  # d'inscription, fix 57bd0ad), mais le clavier restait un piège.
  #
  # Après ce fix : pour le claimant, AUCUN <form> vers update_income_bracket.
  # Le piège disparaît par construction (pas de form = rien à soumettre).
  #
  # H1 prouve le piège AVANT le fix (count: 0 attendu → count: 1 actuel).
  # H3/H4 garantissent qu'on n'a pas tué l'affichage en supprimant le form.

  test "H — claimant anonyme : foyer fiscal en lecture seule (PAS de form, PAS d'input RFR éditable), valeurs et tranche TOUJOURS visibles" do
    orphan = create_orphan_property!(claim_token: GOOD_TOKEN)
    seed_full_analysis!(orphan)
    set_signed_cookie(CLAIM_COOKIE, GOOD_TOKEN)

    get property_path(orphan)
    assert_response :success

    # ─── H1 : AUCUN form ne poste vers update_income_bracket pour le claimant.
    # C'est le test qui ferme le piège : sans form, pas de touche Entrée qui
    # soumet, pas de redirect sign-in, pas de perte de saisie. La sécurité par
    # construction, pas par JS onsubmit fragile.
    assert_select "form[action=?]",
                  update_income_bracket_property_path(orphan),
                  { count: 0 },
                  "Le claimant ne doit avoir AUCUN <form action=#{update_income_bracket_property_path(orphan)}> : le piège clavier (Entrée dans le champ RFR → POST → sign-in → saisie jetée) doit disparaître par construction."

    # ─── H2 : pas d'input éditable (corollaire de H1, mais utile pour
    # détecter une éventuelle régression où on garderait l'input dans un
    # form sans action).
    assert_select "input[name=?]",
                  RFR_INPUT_NAME,
                  { count: 0 },
                  "Le claimant ne doit pas avoir d'input #{RFR_INPUT_NAME} soumissible — le foyer fiscal est en lecture seule pour lui."
    assert_select "input[name=?]",
                  HOUSEHOLD_INPUT_NAME,
                  { count: 0 },
                  "Le claimant ne doit pas avoir d'input #{HOUSEHOLD_INPUT_NAME} soumissible."

    # ─── H3 : les valeurs SONT visibles en lecture seule. Le claimant doit
    # VOIR sur quoi son estimation est bâtie. common_rich_attrs pose
    # household_size: 3 et rfr: 25_000 (cf. critical_path_test.rb).
    # number_to_currency rend "25 000 €" (séparateur insécable côté serveur,
    # mais "25 000" suffit pour notre assertion).
    assert_match "25 000", response.body,
                 "Le RFR du claimant (25 000 €) doit être visible en lecture seule — il a droit à savoir sur quel revenu son estimation est calculée."
    # household_size 3 affiché contextuellement (le markup lecture seule
    # devrait dire quelque chose comme "3 personnes" pour éviter les
    # ambiguïtés sur le chiffre "3" partout dans une page Rails).
    assert_match "3 personnes", response.body,
                 "Le nombre de personnes du foyer (3) doit être visible en lecture seule pour le claimant, dans un contexte non-ambigu."

    # ─── H4 : la tranche dérivée s'affiche. C'est de la lecture pure
    # (property.income_bracket), donc le claimant y a droit. RFR 25 000 €
    # + 3 personnes → tranche dérivée par IncomeBracketCalculator.
    assert_match "Tranche dérivée", response.body,
                 "La 'Tranche dérivée : …' doit rester visible au claimant — c'est de la lecture pure (property.income_bracket), pas un calcul qui exige un compte."
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
