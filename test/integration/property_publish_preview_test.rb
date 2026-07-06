require "test_helper"

# Flux "Publier" : GET /properties/:id/preview → écran de confirmation
# (fiche PUBLIQUE + bannière avec bouton "Confirmer la publication").
#
# Bug d'origine : app/views/properties/preview.html.erb n'existait pas
# (le fichier orphelin s'appelait previews.html.erb, avec un s). Rails
# levait MissingExactTemplate → 406 page blanche en prod.
#
# Règle de confidentialité matérialisée par le flag @preview_mode dans
# preview.html.erb → force is_owner_connecte / can_see_full_dossier à
# false dans show.html.erb, ce qui masque en cascade tous les blocs
# privés (foyer fiscal, valeur, documents, boutons Publier/Modifier).
class PropertyPublishPreviewTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

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
      status:               :analyzed,
      address_source:       "manuel",
      address_confirmed_at: Time.current,
      household_size:       3,
      rfr:                  38_500  # tranche modeste, ne doit PAS fuiter
    )
  end

  # ── Rendu de la vue ─────────────────────────────────────────────────

  test "GET /properties/:id/preview en owner → 200 et rend la bannière" do
    sign_in @owner
    get preview_property_path(@property)
    assert_response :success,
      "Le template preview.html.erb doit exister (bug MissingExactTemplate)"
    assert_match(/Mode prévisualisation/, response.body)
    assert_match(/Confirmer la publication/, response.body)
  end

  test "preview contient un formulaire POST vers publish_property_path" do
    sign_in @owner
    get preview_property_path(@property)
    assert_response :success
    # Le button_to génère un <form action="…/publish" method="post">.
    assert_select "form[action=?][method=?]",
                  publish_property_path(@property), "post"
  end

  test "preview contient un lien Annuler retour vers la fiche owner" do
    sign_in @owner
    get preview_property_path(@property)
    assert_response :success
    assert_select "a[href=?]", property_path(@property)
  end

  # ── Confidentialité : rien de privé ne doit fuiter ────────────────

  test "preview NE contient PAS le foyer fiscal (RFR, household_size, tranche)" do
    sign_in @owner
    get preview_property_path(@property)
    assert_response :success

    # RFR en clair
    refute_match(/38[  ]?500/, response.body,
      "Le RFR (donnée fiscale sensible) ne doit jamais apparaître dans le preview")
    # Champ éditable RFR
    assert_select "input[name='property[rfr]']", { count: 0 },
      "Le champ RFR ne doit pas être rendu dans le preview"
    assert_select "input[name='property[household_size]']", { count: 0 },
      "Le champ household_size ne doit pas être rendu dans le preview"
    # Libellé « Tranche dérivée » (visible uniquement can_edit_aids)
    refute_match(/Tranche dérivée/, response.body)
  end

  test "preview NE contient PAS les boutons d'édition owner" do
    sign_in @owner
    get preview_property_path(@property)
    assert_response :success
    # Bouton "Publier →" du show : gated par is_owner_connecte, doit
    # être masqué en preview_mode (sinon le CTA principal serait dupliqué).
    refute_match(/Publier →/, response.body,
      "Le bouton 'Publier →' du show ne doit pas apparaître dans le preview")
    # Lien "Modifier" du show : idem.
    assert_select "a[href=?]", edit_property_path(@property), { count: 0 }
  end

  test "preview NE contient PAS la section documents" do
    sign_in @owner
    # On attache un document pour que l'ivar Documents ne soit pas vide
    # côté show — c'est la GATE (is_owner_connecte) qu'on vérifie.
    @property.documents.create!(document_type: :dpe)

    get preview_property_path(@property)
    assert_response :success
    # Section documents gated `is_owner_connecte` : libellé "Documents (n)".
    refute_match(/Documents \(\d+\)/, response.body,
      "La section Documents ne doit pas apparaître dans le preview")
  end

  # ── Autorisation ────────────────────────────────────────────────────

  test "GET preview non connecté → redirect Devise (auth requise)" do
    get preview_property_path(@property)
    assert_response :redirect
    assert_match %r{/users/sign_in}, response.location
  end

  test "GET preview par un autre user connecté (non-owner) → redirect /properties" do
    other = User.create!(
      email:                 "other-#{SecureRandom.hex(4)}@example.com",
      password:              "password123",
      password_confirmation: "password123",
      confirmed_at:          Time.current
    )
    sign_in other
    get preview_property_path(@property)
    assert_redirected_to properties_path,
      "set_property_for_write refuse tout non-owner, même sur un bien published"
  end

  test "GET preview sur un bien PUBLISHED par un tiers connecté → toujours refusé" do
    @property.update!(status: :published)
    other = User.create!(
      email:                 "other2-#{SecureRandom.hex(4)}@example.com",
      password:              "password123",
      password_confirmation: "password123",
      confirmed_at:          Time.current
    )
    sign_in other
    get preview_property_path(@property)
    assert_redirected_to properties_path,
      "Preview owner-only : même sur un bien public, un tiers n'a pas à voir " \
      "l'écran 'voici ce qu'on va publier'"
  end

  # ── Enchaînement complet du flux ───────────────────────────────────

  test "flux complet : preview → publish → status devient published" do
    sign_in @owner
    get preview_property_path(@property)
    assert_response :success

    assert_equal "analyzed", @property.status
    post publish_property_path(@property)
    assert_redirected_to property_path(@property)
    assert_equal "published", @property.reload.status
  end

  # ── Bloc proposition en preview : rendu mais INERTE ───────────────

  test "preview : le bloc proposition est présent mais tous ses contrôles sont dans un <fieldset disabled>" do
    sign_in @owner
    get preview_property_path(@property)
    assert_response :success

    # Le bloc est rendu (argument produit : "voici ce qui apparaîtra
    # sur votre annonce"), donc le titre doit être là.
    assert_select "#formulaire-proposition"

    # Tous les inputs/submit du form vivent dans un fieldset disabled.
    # <fieldset disabled> désactive nativement tous les contrôles
    # descendants — c'est la barrière DOM/HTML5 la plus fiable.
    assert_select "#formulaire-proposition fieldset[disabled]", { minimum: 1 },
      "Le bloc proposition doit être enveloppé dans un <fieldset disabled> en preview"

    # Aucun input ni submit ne doit exister EN DEHORS du fieldset disabled.
    # (Sinon un contrôle serait cliquable.)
    all_inputs  = css_select("#formulaire-proposition form input, #formulaire-proposition form textarea").size
    inputs_in_disabled = css_select("#formulaire-proposition fieldset[disabled] input, #formulaire-proposition fieldset[disabled] textarea").size
    assert_equal all_inputs, inputs_in_disabled,
      "Tous les champs du form doivent être sous le fieldset disabled — trouvés #{all_inputs}, dont #{inputs_in_disabled} dans le fieldset"
  end

  test "preview : ruban explicatif présent sur le bloc proposition" do
    sign_in @owner
    get preview_property_path(@property)
    assert_response :success
    assert_select "#offer-form-preview-ribbon"
    assert_match(/Ce module s'affichera pour les artisans et investisseurs/, response.body)
  end

  test "show hors preview (tiers prestataire sur bien publié) : form actif, sans ruban ni fieldset disabled" do
    @property.update!(status: :published)
    prestataire = User.create!(
      email:                 "artisan-#{SecureRandom.hex(4)}@example.com",
      password:              "password123",
      password_confirmation: "password123",
      role:                  :prestataire,
      confirmed_at:          Time.current
    )
    sign_in prestataire

    get property_path(@property)
    assert_response :success

    # Bloc rendu (tiers non-owner voit unless can_see_full_dossier)
    assert_select "#formulaire-proposition"
    # Pas de ruban preview
    assert_select "#offer-form-preview-ribbon", false,
      "Aucun ruban preview ne doit apparaître dans la vraie fiche publiée"
    # Pas de fieldset disabled : le form doit être actif
    assert_select "#formulaire-proposition fieldset[disabled]", false,
      "Sur la vraie fiche publiée, le form doit rester ACTIF (pas de fieldset disabled)"
    # Submit actif
    assert_select "#formulaire-proposition input[type=submit]:not([disabled])",
      { minimum: 1 },
      "Le bouton d'envoi doit être actif pour un vrai visiteur prestataire"
  end

  test "show sur bien publié vu par un ANONYME : CTA d'inscription (form non rendu, comportement inchangé)" do
    @property.update!(status: :published)
    # Pas de sign_in, pas de cookie.
    get property_path(@property)
    assert_response :success
    # Le partial rend le CTA "S'inscrire" à la place du form quand
    # le visiteur n'est pas connecté (comportement existant).
    # Note : l'apostrophe est HTML-encodée en &#39; par link_to,
    # d'où le motif "Créez un compte prestataire" en assertion stable.
    assert_match(/Créez un compte prestataire/, response.body)
    assert_select "a[href=?]", new_user_registration_path,
      { minimum: 1 },
      "Lien d'inscription attendu pour un anonyme sur une fiche publiée"
    # Pas de ruban preview.
    assert_select "#offer-form-preview-ribbon", false
  end

  # ── Anti-régression du nom de fichier ──────────────────────────────

  test "fichier legacy previews.html.erb (avec s) ne doit pas revenir" do
    legacy = Rails.root.join("app/views/properties/previews.html.erb")
    refute File.exist?(legacy),
      "Le fichier orphelin previews.html.erb a été supprimé — il ne doit pas " \
      "réapparaître (source de la confusion nom-de-fichier qui a causé le 406)"
  end
end
