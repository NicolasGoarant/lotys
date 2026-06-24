require "test_helper"
require "active_job/test_helper"

# Création d'une Property orpheline par un visiteur anonyme (commit 3/5).
#
# Flux complet :
#   POST /properties sans connexion → Property créée avec user_id nil,
#   claim_token aléatoire, cookie signé déposé, PropertyAnalysisJob enqueué,
#   redirect vers la fiche. La fiche est ensuite lisible parce que le
#   cookie de la session de test transporte le jeton.
#
# Garde-fous :
#   - L'orpheline a bien user_id nil + un claim_token unique non nul.
#   - Le job d'analyse est enqueué (le pipeline tourne sur les orphelines).
#   - Le redirect suivi répond 200 (cookie signé lu correctement par show).
#   - Régression : visiteur CONNECTÉ → comportement inchangé (current_user.properties).
class OrphanClaimCreateTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    # Adapter :test → jobs enqueués mais NON exécutés (pas d'appel Anthropic).
    @_original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test

    # Rack::Attack limite "properties/ip" à 3 POSTs/heure (cf.
    # config/initializers/rack_attack.rb). Le cache mémoire accumule
    # entre les tests d'un même process → on désactive le middleware
    # pour ce fichier. Restauré en teardown.
    @_rack_attack_was_enabled = Rack::Attack.enabled
    Rack::Attack.enabled = false
  end

  teardown do
    ActiveJob::Base.queue_adapter = @_original_adapter
    Rack::Attack.enabled = @_rack_attack_was_enabled
  end

  # ─── Cas 1 : visiteur anonyme crée une orpheline ─────────────────────

  test "POST /properties anonyme crée une orpheline avec claim_token et enqueue l'analyse" do
    assert_difference -> { Property.where(user_id: nil).count }, +1 do
      assert_enqueued_with(job: PropertyAnalysisJob) do
        post properties_path, params: {
          property: {
            address: "14 rue des Tilleuls",
            city:    "Vandœuvre-lès-Nancy",
            zipcode: "54500"
          }
        }
      end
    end

    orphan = Property.where(user_id: nil).order(:created_at).last
    assert_not_nil orphan.claim_token, "L'orpheline doit porter un claim_token"
    assert_operator orphan.claim_token.length, :>=, 32,
                    "Le claim_token doit être suffisamment long pour éviter toute énumération"
    assert_equal "analyzing", orphan.status,
                 "L'orpheline doit passer en :analyzing pour que le pipeline tourne"

    assert_redirected_to property_path(orphan)
  end

  # ─── Cas 2 : le cookie déposé permet de lire la fiche juste après ───

  test "POST anonyme puis follow_redirect : la fiche s'affiche et contient bien les données du bien (chaîne création → cookie → lecture OK)" do
    # Aucun cookie posé à la main. C'est la branche anon de #create qui doit
    # déposer write_claim_cookie!(token), et c'est set_property_for_read qui
    # doit ensuite reconnaître ce cookie via claimable_by_browser?. Si l'une
    # des deux moitiés manque, ce test casse.
    post properties_path, params: {
      property: {
        address: "14 rue des Tilleuls",
        city:    "Vandœuvre-lès-Nancy",
        zipcode: "54500"
      }
    }

    follow_redirect!
    assert_response :success,
                    "La fiche de l'orpheline doit répondre 200 grâce au cookie signé déposé " \
                    "à la création, reçu status=#{response.status}, location=#{response.location.inspect}"

    # Preuve que la page rendue est BIEN la fiche du bien anonyme, pas une
    # redirection vers root ou une page d'erreur custom 200.
    assert_match "Vandœuvre-lès-Nancy", response.body,
                 "La fiche rendue doit contenir la ville saisie — sinon on est tombé sur " \
                 "une autre page (root, erreur, etc.) qui renvoie 200 sans afficher l'orpheline"
    assert_match "14 rue des Tilleuls", response.body,
                 "La fiche rendue doit contenir l'adresse saisie"
  end

  # ─── Cas 3 : unicité des claim_token entre créations consécutives ────

  test "deux créations anonymes consécutives produisent deux claim_token distincts" do
    post properties_path, params: { property: { address: "1 rue A", city: "Nancy", zipcode: "54000" } }
    token1 = Property.where(user_id: nil).order(:created_at).last.claim_token

    # Nouvelle session pour ne pas hériter du cookie précédent (sinon le
    # 2e bien serait écrasé côté cookie mais ce n'est pas ce qu'on teste ici).
    reset!

    post properties_path, params: { property: { address: "2 rue B", city: "Nancy", zipcode: "54000" } }
    token2 = Property.where(user_id: nil).order(:created_at).last.claim_token

    assert_not_equal token1, token2,
                     "Deux orphelines successives doivent avoir des claim_token distincts (SecureRandom)"
  end

  # ─── Cas 4 : validations cassées → render :new (pas de save) ─────────

  test "POST anonyme avec données invalides (zipcode 1234) → ne crée RIEN, rend :new" do
    assert_no_difference -> { Property.where(user_id: nil).count } do
      post properties_path, params: {
        property: {
          address: "1 rue Test",
          city:    "Nancy",
          zipcode: "1234"   # invalide : exige 5 chiffres
        }
      }
    end

    assert_response :unprocessable_entity,
                    "Validations cassées doivent re-rendre :new avec 422, pas créer une orpheline incomplète"
  end

  # ─── Régression cas 5 : visiteur connecté inchangé ───────────────────

  test "régression : visiteur CONNECTÉ → la Property est rattachée à current_user, sans claim_token" do
    user = create_confirmed_user!
    sign_in user

    assert_difference -> { user.properties.count }, +1 do
      post properties_path, params: {
        property: { address: "3 rue Possédée", city: "Nancy", zipcode: "54000" }
      }
    end

    created = user.properties.order(:created_at).last
    assert_equal user.id, created.user_id, "Le bien doit être rattaché à current_user"
    assert_nil created.claim_token,
               "Un bien créé en connecté ne doit PAS porter de claim_token (l'orpheline est un mécanisme anonyme)"
  end

  # ─── Helper ──────────────────────────────────────────────────────────

  private

  include Devise::Test::IntegrationHelpers

  def create_confirmed_user!(email: "test-#{SecureRandom.hex(4)}@example.com")
    User.create!(
      email:                 email,
      password:              "password123",
      password_confirmation: "password123",
      confirmed_at:          Time.current
    )
  end
end
