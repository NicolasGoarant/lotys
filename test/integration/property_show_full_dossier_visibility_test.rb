require "test_helper"
require_relative "../support/aid_rules_helper"

# Asservit la règle CIBLE de la vue show :
#
#   « Voit la fiche COMPLÈTE (jauge interactive + bloc aides + valeur estimée) »
#     = propriétaire connecté de son bien
#       OU détenteur en cookie signé du claim_token d'une orpheline
#
#   « Voit la vue artisan/publique »
#     = quiconque d'autre regardant un bien :published
#
# Le bug à corriger : aujourd'hui `is_owner` dans show.html.erb exige
# `user_signed_in? && current_user == @property.user`, ce qui EXCLUT le
# créateur anonyme légitime du parcours d'estimation, qui détient pourtant
# son cookie signé. Test A doit donc échouer AVANT le fix, B/C/D verts.
#
# Test B (étanchéité) est le plus important : il prouve qu'élargir la
# vue au claimant n'ouvre PAS le robinet à n'importe quel visiteur d'un
# bien publié.
class PropertyShowFullDossierVisibilityTest < ActionDispatch::IntegrationTest
  include AidRulesHelper

  CLAIM_COOKIE = ClaimToken::CLAIM_COOKIE
  GOOD_TOKEN   = "JETON_CLAIMANT_LEGITIME"
  OTHER_TOKEN  = "JETON_TIERS_QUI_PASSE_PAR_LA"

  # Marqueurs HTML/texte EXCLUSIFS de la fiche complète. Si l'un d'eux
  # apparaît sur la vue artisan, c'est une fuite — d'où leur usage dans
  # les deux sens (assert pour A/D, refute pour B).
  AIDES_HEADING       = "Aides auxquelles vous avez droit"
  VALUE_HEADING       = "Valeur estimée"
  AIDES_BLOCK_ID      = "aides"
  SLIDER_ID           = "dpe-slider"

  setup do
    seed_aid_rules!
  end

  # ─── A. Bug à corriger : claimant anonyme doit voir la FICHE COMPLÈTE ─

  test "A — visiteur anonyme avec le claim_token de SON orpheline en cookie voit la fiche complète (aides + jauge interactive + valeur estimée)" do
    orphan = create_orphan_property!(claim_token: GOOD_TOKEN)
    seed_full_analysis!(orphan)
    set_signed_cookie(CLAIM_COOKIE, GOOD_TOKEN)

    get property_path(orphan)
    assert_response :success,
                    "Le claimant doit déjà pouvoir LIRE son orpheline (concern ClaimToken), reçu #{response.status}"

    # Bloc aides — marqueur DOM + texte
    assert_select "div##{AIDES_BLOCK_ID}", { count: 1 },
                  "Le claimant doit voir le bloc #aides — c'est exactement le bug : aujourd'hui is_owner=false, donc bloc absent"
    assert_match AIDES_HEADING, response.body,
                 "Le claimant doit voir le titre '#{AIDES_HEADING}' du bloc Aides"

    # Jauge DPE interactive (réservée à la branche else de `if !is_owner`)
    assert_select "input##{SLIDER_ID}", { count: 1 },
                  "Le claimant doit voir la jauge DPE INTERACTIVE (input#dpe-slider), pas la version statique"

    # Valeur estimée (réservée à `v && is_owner`)
    assert_match VALUE_HEADING, response.body,
                 "Le claimant doit voir la '#{VALUE_HEADING}' de son bien"

    # Et il ne doit PAS voir le bloc artisan : il est sur SON bien, pas en train
    # d'enchérir. (id stable du partial _offer_form — résiste à l'HTML-escape
    # de l'apostrophe dans le libellé "S'inscrire…".)
    assert_select "div#formulaire-proposition", { count: 0 },
                  "Le claimant ne doit pas se voir proposer le formulaire artisan sur son propre dossier"
  end

  # ─── B. ÉTANCHÉITÉ — visiteur anonyme sans cookie sur bien PUBLIÉ ─────
  #
  # Le test le plus important. Le bien publié est volontairement RICHE
  # (analyse complète, équipements, revenus) pour qu'une régression qui
  # ouvrirait le bloc aides aux visiteurs anonymes déclenche bien le
  # test, au lieu de passer trivialement faute de données à afficher.
  test "B — visiteur SANS cookie sur un bien PUBLIÉ ne voit JAMAIS aides ni valeur estimée (étanchéité critique)" do
    owner = create_confirmed_user!
    published = create_published_property!(owner: owner)
    seed_full_analysis!(published)

    # Strictement anonyme : ni sign_in, ni cookie.
    get property_path(published)
    assert_response :success,
                    "Le bien publié reste accessible aux visiteurs anonymes (vue artisan), reçu #{response.status}"

    # Bloc aides : ABSENT
    assert_select "div##{AIDES_BLOCK_ID}", { count: 0 },
                  "Le bloc #aides ne doit JAMAIS être rendu pour un visiteur anonyme — données privées"
    assert_no_match AIDES_HEADING, response.body,
                    "Le titre '#{AIDES_HEADING}' ne doit pas apparaître pour un visiteur anonyme"

    # Valeur estimée : ABSENTE
    assert_no_match VALUE_HEADING, response.body,
                    "La '#{VALUE_HEADING}' ne doit jamais fuir vers un visiteur anonyme"

    # Jauge interactive : ABSENTE (le visiteur a la version statique)
    assert_select "input##{SLIDER_ID}", { count: 0 },
                  "Le slider DPE interactif est réservé à la fiche complète"

    # La vue artisan, elle, doit bien être active : présence du formulaire
    # de proposition (id stable du partial _offer_form, robuste à l'HTML-escape
    # de l'apostrophe dans le CTA "S'inscrire…").
    assert_select "div#formulaire-proposition", { count: 1 },
                  "Sans compte, le visiteur sur un bien publié doit voir le formulaire de proposition (vue artisan)"
  end

  # ─── C. Étanchéité : mauvais cookie sur l'orpheline d'autrui ──────────

  test "C — visiteur avec le claim_token d'une AUTRE orpheline ne récupère même pas le record (redirect)" do
    orphan_tiers = create_orphan_property!(claim_token: GOOD_TOKEN)
    seed_full_analysis!(orphan_tiers)
    set_signed_cookie(CLAIM_COOKIE, OTHER_TOKEN) # cookie qui ne matche pas

    get property_path(orphan_tiers)

    assert_response :redirect,
                    "Sans le bon jeton, l'orpheline ne doit pas être lisible — l'accès au record doit être refusé"
    assert_redirected_to root_path

    # Garantie supplémentaire : aucun marqueur de fiche complète n'a fui
    # dans le corps de la réponse (utile si on changeait un jour de
    # comportement de redirect_to → render).
    assert_no_match AIDES_HEADING, response.body
    assert_no_match VALUE_HEADING, response.body
  end

  # ─── D. Régression — propriétaire connecté voit toujours sa fiche complète ─

  test "D — propriétaire connecté sur son bien voit la fiche complète (régression)" do
    owner = create_confirmed_user!
    property = create_owned_property!(owner: owner)
    seed_full_analysis!(property)

    sign_in owner
    get property_path(property)
    assert_response :success

    assert_select "div##{AIDES_BLOCK_ID}", { count: 1 },
                  "Le propriétaire connecté doit toujours voir le bloc #aides"
    assert_match AIDES_HEADING, response.body
    assert_select "input##{SLIDER_ID}", { count: 1 },
                  "Le propriétaire doit garder la jauge interactive"
    assert_match VALUE_HEADING, response.body
  end

  # ─── Helpers ──────────────────────────────────────────────────────────

  private

  include Devise::Test::IntegrationHelpers

  # Pose un cookie signé Rails dans la jar du test d'intégration.
  # Même mécanique que orphan_claim_show_test.rb (factorisation possible
  # plus tard si le pattern se répand — pour l'instant on duplique
  # plutôt que de coupler les deux fichiers de test).
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

  # Attributs « assez riches » pour que le calcul d'aides AIT quelque chose
  # à produire (PAC + foyer modeste + maison ancienne → MPR Par geste non nul,
  # cf. critical_path_test.rb#"GET /properties/:id rend des aides non vides…").
  # Sans ça, le bloc aides serait absent même pour le propriétaire et nos
  # marqueurs ne discrimineraient plus rien.
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
      address:              "1 rue Publiée",
      city:                 "Nancy",
      zipcode:              "54000",
      status:               :published,
      # C2 : la publication exige une adresse confirmée. Ce bien étant
      # fixture "déjà publiée", on considère la confirmation faite.
      address_source:       "manuel",
      address_confirmed_at: Time.current,
      **common_rich_attrs
    )
    p.save!
    p.update!(pac_air_eau: true)
    p
  end

  # Pose une Analysis avec un content JSON suffisant pour que la vue ait
  # `e` (énergie) ET `v` (valeur) truthy — sans ces clés, les blocs sont
  # gated en amont et l'étanchéité testée serait triviale.
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
