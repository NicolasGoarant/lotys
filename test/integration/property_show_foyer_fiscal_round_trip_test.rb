require "test_helper"
require_relative "../support/aid_rules_helper"

# Bug bien 232 (copro classe E) — foyer fiscal effacé après « Mettre à jour
# les aides ». L'utilisateur voyait ses champs household_size / rfr revenus
# à vide + le bandeau « Renseignez vos revenus » après un tour par
# update_travaux_selection.
#
# Ce test verrouille le CONTRAT ATTENDU : les champs re-rendent TOUJOURS
# les valeurs enregistrées, et le bandeau « non renseignés » n'apparaît
# QUE quand la DB est réellement vide.
#
# Test C : contrat d'échec de update_income_bracket (redirect + ALERT
# quand la sauvegarde ne passe pas — plus de « faux OK » silencieux).
class PropertyShowFoyerFiscalRoundTripTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include AidRulesHelper

  setup do
    seed_aid_rules!
    @owner    = User.create!(email: "foyer-rt-#{SecureRandom.hex(4)}@lauze.eu",
                             password: "password", password_confirmation: "password",
                             confirmed_at: Time.current)
    @property = @owner.properties.create!(
      address: "12 rue Copropriété", city: "Nancy", zipcode: "54000",
      surface: 72, property_type: "appartement", construction_year: 1965,
      dpe_class: "E", energie_chauffage: "gaz",
      status: :analyzed
    )
    seed_analysis!(@property)
    sign_in @owner
  end

  # ── A. Round-trip nominal ─────────────────────────────────────────────
  # PATCH bracket → GET show → PATCH travaux → GET show. Les valeurs
  # foyer fiscal doivent survivre au tour complet, le bandeau ne doit
  # jamais apparaître une fois la sauvegarde faite.
  test "A — round-trip complet : household_size/rfr survivent à update_travaux_selection" do
    # 1. Sauvegarde initiale du foyer.
    patch update_income_bracket_property_path(@property),
          params: { property: { household_size: 3, rfr: 35_000 } }
    assert_redirected_to property_path(@property, anchor: "aides")
    assert_match(/Foyer fiscal mis à jour/i, flash[:notice].to_s)

    @property.reload
    assert_equal 3,      @property.household_size, "household_size persisté"
    assert_equal 35_000, @property.rfr,           "rfr persisté"
    assert @property.income_bracket.present?,     "income_bracket dérivé (before_save)"

    # 2. GET show : les inputs doivent porter les valeurs persistées.
    get property_path(@property)
    assert_response :success
    assert_input_value "property[household_size]", "3"
    assert_input_value "property[rfr]",            "35000"
    refute_match(/Renseignez vos revenus/, response.body,
      "Bandeau 'Renseignez vos revenus' ne doit PAS apparaître : DB peuplée")

    # 3. Un tour par update_travaux_selection (change les cases + dpe_target).
    #    C'est le point exact où le user 232 perdait ses valeurs.
    patch update_travaux_selection_property_path(@property),
          params: { property: { isolation_murs: "1", dpe_target: "D" } }
    assert_redirected_to property_path(@property, anchor: "travaux")

    @property.reload
    assert_equal 3,      @property.household_size,
      "household_size NE DOIT PAS être touché par update_travaux_selection " \
      "(le controller n'écrit que travaux_selection + dpe_target)"
    assert_equal 35_000, @property.rfr,
      "rfr NE DOIT PAS être touché par update_travaux_selection"
    assert @property.income_bracket.present?,
      "income_bracket doit rester dérivé"

    # 4. GET show après le tour travaux : les champs restent peuplés,
    #    pas de bandeau « non renseignés ».
    get property_path(@property)
    assert_response :success
    assert_input_value "property[household_size]", "3",
      "Après update_travaux_selection, le champ household_size doit re-rendre 3 " \
      "(bug bien 232 : re-rendait vide)"
    assert_input_value "property[rfr]", "35000",
      "Après update_travaux_selection, le champ rfr doit re-rendre 35000"
    refute_match(/Renseignez vos revenus/, response.body,
      "Le bandeau 'Renseignez vos revenus' ne doit apparaître QUE si la DB " \
      "est vide (règle projet : jamais de bandeau incorrect quand la donnée existe)")
  end

  # ── B. Bandeau HONNÊTE quand la DB est réellement vide ────────────────
  # Vérifie l'autre sens de la règle : la partie « ne doit apparaître QUE
  # si la base est réellement vide » se traduit aussi par « DOIT apparaître
  # quand la base EST vide ». Anti-régression d'une éventuelle sur-correction.
  test "B — DB vide : bandeau 'Renseignez vos revenus' présent + inputs sans value" do
    assert_nil @property.household_size, "sanity : DB vide au départ"
    assert_nil @property.rfr

    get property_path(@property)
    assert_response :success

    assert_match(/Renseignez vos revenus/, response.body,
      "Quand rfr est nil ET can_edit_aids, le bandeau doit être présent")
    # Les inputs n'ont PAS d'attribut value (ou value vide).
    household = response.body.scan(/<input[^>]*name="property\[household_size\]"[^>]*>/).first
    rfr_input = response.body.scan(/<input[^>]*name="property\[rfr\]"[^>]*>/).first
    assert household, "Input household présent dans le form"
    assert rfr_input, "Input rfr présent dans le form"
    refute_match(/value="[1-9]/, household,
      "Aucune valeur numérique injectée quand household_size est nil. HTML: #{household}")
    refute_match(/value="[1-9]/, rfr_input,
      "Aucune valeur numérique injectée quand rfr est nil. HTML: #{rfr_input}")
  end

  # ── C. Contrat d'échec explicite du controller ────────────────────────
  # Régression bien 232 : le controller redirigeait toujours avec un
  # notice de succès, même quand @property.update échouait. Un user
  # voyait « Foyer fiscal mis à jour » alors que rien n'avait été
  # persisté. Maintenant, on redirige avec un ALERT explicite.
  test "C — validation qui échoue → redirect avec ALERT (plus de faux OK)" do
    # household_size = 25 → viole `less_than: 20` (max foyer fiscal ALEC).
    patch update_income_bracket_property_path(@property),
          params: { property: { household_size: 25, rfr: 35_000 } }
    assert_redirected_to property_path(@property, anchor: "aides")

    assert flash[:alert].present?,
      "Une validation qui échoue DOIT poser un flash[:alert] — plus de faux OK silencieux"
    assert_nil flash[:notice],
      "Aucun notice de succès quand la sauvegarde a échoué"
    assert_match(/Impossible d'enregistrer/i, flash[:alert],
      "Message d'alert doit citer l'échec de manière lisible. Reçu : #{flash[:alert]}")

    @property.reload
    assert_nil @property.household_size,
      "Rien de persisté quand la validation échoue"
    assert_nil @property.rfr
  end

  private

  def seed_analysis!(property)
    Analysis.create!(property: property, content: {
      "valeur"  => { "estimation_basse" => 180_000, "estimation_haute" => 220_000 },
      "energie" => {
        "dpe_estime" => "E",
        "dpe_cible"  => "D",
        "travaux"    => [
          { "poste" => "Isolation murs", "priorite" => 1, "cout_min" => 10_000, "cout_max" => 20_000 },
          { "poste" => "Ventilation VMC", "priorite" => 2, "cout_min" => 2_000, "cout_max" => 4_000 },
          { "poste" => "Menuiseries",     "priorite" => 3, "cout_min" => 5_000, "cout_max" => 10_000 }
        ]
      },
      "idees"   => { "scenarios" => [] }
    }.to_json)
  end

  # Extrait l'attribut value= d'un input identifié par son nom, sans
  # dépendre de l'ordre des attributs dans le HTML (Rails peut placer
  # value avant ou après name selon les versions).
  def assert_input_value(input_name, expected_value, extra_msg = nil)
    input = response.body.scan(/<input[^>]*name="#{Regexp.escape(input_name)}"[^>]*>/).first
    assert input, "Input name='#{input_name}' introuvable dans la réponse"
    m = input.match(/value="([^"]*)"/)
    assert m, "Attribut value= absent sur l'input #{input_name}. HTML: #{input}"
    assert_equal expected_value, m[1],
      "Valeur inattendue pour #{input_name}. HTML: #{input}. #{extra_msg}"
  end
end
