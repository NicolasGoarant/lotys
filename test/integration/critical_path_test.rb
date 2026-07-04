require "test_helper"
require "active_job/test_helper"
require_relative "../support/aid_rules_helper"

# ═══════════════════════════════════════════════════════════════════════
#   Critical Path — smoke tests des parcours clés avant envoi ALEC.
#
#   Objectif : s'assurer que les routes vitrines, la page projets et la
#   page résultats d'un bien ne plantent pas. Pas de logique métier ici,
#   ce sont des garde-fous "200, pas 500" pour la mise en production.
#
#   Stratégie HTTP / Anthropic :
#     - Aucun stub réseau (webmock absent du Gemfile). L'adaptateur de jobs
#       par défaut en test (:test) enqueue mais n'exécute pas, donc
#       PropertyAnalysisJob (Anthropic + BAN) n'est jamais déclenché.
#     - La page show n'appelle pas l'API : elle ne fait que lire la DB
#       + exécuter AidCalculatorService (in-process, pas de HTTP).
# ═══════════════════════════════════════════════════════════════════════
class CriticalPathTest < ActionDispatch::IntegrationTest
  include AidRulesHelper
  include ActiveJob::TestHelper

  # L'app tourne sur GoodJob en dev/prod. En test, on bascule sur l'adapter
  # `:test` (queue en mémoire) le temps du fichier : ça permet d'utiliser
  # assert_enqueued_with et garantit qu'aucun job n'est réellement exécuté
  # (donc pas d'appel Anthropic ni BAN).
  setup do
    @_original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    seed_aid_rules!
  end

  teardown do
    ActiveJob::Base.queue_adapter = @_original_adapter
  end

  # ── 1. Home : 200 + les 3 cards persona ─────────────────────────────
  test "GET / répond 200 et affiche les 3 cards persona" do
    get root_path
    assert_response :success

    # Le titre h2 contient un `<br class="sm:hidden">` intercalé pour
    # forcer le saut de ligne mobile après la virgule. On cible donc le
    # h2 et on tolère un espace variable (le `<br>` disparaît dans le
    # `.text` Nokogiri mais laisse le whitespace d'indentation autour) —
    # évite qu'un ajustement de balisage casse à nouveau l'assertion.
    assert_select "h2", { text: /Trois publics,\s*un même outil/ },
      "Titre h2 « Trois publics, un même outil » attendu sur la home"
    assert_match "Je suis propriétaire", response.body
    assert_match "Je suis artisan RGE",   response.body
    assert_match "Je suis une collectivité", response.body
  end

  # ── 2. Les 3 entrées persona ouvrent une page 200 ───────────────────
  test "les 3 pages persona répondent 200" do
    [proprietaires_path, artisans_path, collectivites_path].each do |path|
      get path
      assert_response :success, "#{path} devrait répondre 200, reçu #{response.status}"
    end
  end

  # ── 3. Parcours d'estimation de bout en bout ────────────────────────
  # GET new_property_path → POST /properties → redirection vers show →
  # rendu de la page résultats sans 500.
  #
  # PropertyAnalysisJob est enqueué mais NON exécuté (adapter :test), donc
  # aucun appel Anthropic ni BAN n'est déclenché — le scénario reste
  # offline et déterministe.
  test "parcours estimation (new → create → show) sans 500, job enqueué non exécuté" do
    user = create_confirmed_user!

    sign_in user

    # 3a. La page formulaire répond
    get new_property_path
    assert_response :success

    # 3b. POST create avec les seuls champs strictement requis par les
    #     validations (adresse, ville, code postal). Le reste est rempli
    #     par l'analyse Claude → ici on vérifie juste que le pipeline
    #     ne plante pas et que le job est enqueué.
    assert_enqueued_with(job: PropertyAnalysisJob) do
      post properties_path, params: {
        property: {
          address: "1 rue du Test",
          city:    "Nancy",
          zipcode: "54000"
        }
      }
    end

    assert_response :redirect
    property = user.properties.last
    assert property, "La propriété aurait dû être créée"
    assert_redirected_to property_path(property)

    # 3c. La page show répond 200 (status :analyzing, données partielles
    #     — l'utilisateur voit la card "analyse en cours" + état partiel
    #     des aides, mais aucun 500).
    follow_redirect!
    assert_response :success
  end

  # ── 4. Résultats avec aides NON VIDES sur un cas connu ──────────────
  # On pré-remplit un bien complet (DPE, surfaces, équipements, revenus)
  # comme l'aurait fait l'analyse Claude. Le AidCalculatorService doit
  # alors produire au moins une subvention (MPR Par geste sur la PAC).
  test "GET /properties/:id rend des aides non vides pour un cas pré-rempli" do
    user = create_confirmed_user!

    property = user.properties.create!(
      address:           "1 rue du Test",
      city:              "Nancy",
      zipcode:           "54000",
      surface:           100,
      property_type:     "maison",
      construction_year: 1970,
      dpe_class:         "F",
      dpe_target:        "C",
      household_size:    3,
      rfr:               25_000, # → modeste (≤ 39 148)
      status:            :analyzed
    )
    # Ces setters écrivent dans equipements_selection (store_accessor).
    property.update!(pac_air_eau: true)

    sign_in user
    get property_path(property)
    assert_response :success

    result = AidCalculatorService.new(property).call
    assert_operator result[:total_subventions], :>, 0,
      "Total subventions devrait être > 0 pour PAC + modeste + maison ≥ 15 ans, " \
      "reçu #{result[:total_subventions]} (errors=#{result[:errors].inspect})"
    assert result[:subventions].any?,
      "Devrait avoir au moins une subvention, reçu : #{result[:subventions].inspect}"
  end

  # ── 6. Page projets / biens à rénover ──────────────────────────────
  # /offers est gated par authenticate_user! puis require_prestataire pour
  # new/create. L'index est accessible à tout user connecté (la vue
  # branche sur le role). On vérifie le 200 côté prestataire — c'est le
  # parcours "découverte des projets" depuis la page /artisans.
  test "GET /offers répond 200 pour un prestataire connecté" do
    prestataire = create_confirmed_user!(
      email: "presta-#{SecureRandom.hex(4)}@example.com",
      role:  :prestataire
    )

    sign_in prestataire
    get offers_path
    assert_response :success
  end

  private

  # Crée un utilisateur Devise confirmé en bypass de l'email de confirmation.
  # role par défaut :proprietaire (cf. User#after_initialize).
  def create_confirmed_user!(email: "test-#{SecureRandom.hex(4)}@example.com", role: :proprietaire)
    User.create!(
      email:                 email,
      password:              "password123",
      password_confirmation: "password123",
      confirmed_at:          Time.current,
      role:                  role
    )
  end
end
