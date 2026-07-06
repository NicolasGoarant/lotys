require "test_helper"

# Tests d'intégration du portail collectivité (C4 controller/route).
# La vue complète (C5) et le rattachement des biens (C6) sont testés
# dans leurs commits respectifs.
class CollectivitesPortailTest < ActionDispatch::IntegrationTest
  def setup_grand_nancy(active: true)
    Collectivite.create!(
      name:          "Métropole du Grand Nancy",
      slug:          "grand-nancy",
      primary_color: "#0066a1",
      welcome_text:  "Bienvenue",
      insee_codes:   %w[54395 54547],  # Nancy + Vandœuvre
      active:        active
    )
  end

  # ── Accès ─────────────────────────────────────────────────────────────

  test "GET /collectivites/grand-nancy actif → 200 et rend le nom" do
    setup_grand_nancy
    get "/collectivites/grand-nancy"
    assert_response :success
    assert_match "Métropole du Grand Nancy", response.body
    assert_select "#collectivite-portail[data-slug='grand-nancy']"

    # Anti-régression : aucun fragment de commentaire ERB ne doit fuiter
    # dans le HTML rendu du portail (même risque que sur properties/show).
    refute_match(/-%>/, response.body,
      "Un délimiteur ERB fermant '-%>' apparaît en texte visible sur le portail")
    refute_match(/CSS invalide/, response.body,
      "Un fragment de commentaire ERB (« CSS invalide ») a fuité sur le portail")
  end

  test "GET /collectivites/<slug inconnu> → redirect vers /collectivites avec alert" do
    get "/collectivites/inconnue"
    assert_redirected_to collectivites_path
    follow_redirect!
    assert_match(/n'existe pas ou n'est plus disponible/, flash[:alert] || "")
  end

  test "GET /collectivites/<slug désactivé> → redirect (pas de leak actif/inactif)" do
    setup_grand_nancy(active: false)
    get "/collectivites/grand-nancy"
    assert_redirected_to collectivites_path
  end

  # ── Non-régression sur la route marketing ─────────────────────────────

  test "GET /collectivites sans slug → page marketing existante (non régressée)" do
    get "/collectivites"
    assert_response :success
    # La route marketing est déclarée AVANT la route portail.
    # Ce test verrouille cet ordre : sans lui, une régression de config
    # ferait matcher /collectivites → controller portail avec slug vide.
  end

  test "page marketing /collectivites : le discours DÉCIDEUR reste intact (audience distincte du portail)" do
    get "/collectivites"
    assert_response :success
    # Ces éléments visent les élus/EPCI, ils DOIVENT rester ici même
    # après le nettoyage habitant du portail /collectivites/:slug.
    assert_match(/Ce que Lauze fait pour votre territoire/, response.body,
      "Le titre décideur doit rester sur la page marketing")
    assert_match(/Piloter votre politique/, response.body,
      "La colonne pilotage doit rester sur la page marketing")
    assert_match(/Tableau de bord/, response.body,
      "La promesse tableau de bord doit rester sur la page marketing")
  end

  # ── Compteur biens ────────────────────────────────────────────────────

  test "compteur biens : ne compte QUE les biens analyzed/published sur les INSEE couverts" do
    setup_grand_nancy

    # Sur le territoire (Nancy) + analyzed → compté.
    Property.create!(
      address: "1", city: "Nancy", zipcode: "54000",
      claim_token: SecureRandom.hex(16),
      code_insee: "54395", status: :analyzed
    )
    # Sur le territoire (Vandœuvre) + published → compté.
    Property.create!(
      address: "2", city: "Vandœuvre", zipcode: "54500",
      claim_token: SecureRandom.hex(16),
      code_insee: "54547", status: :published,
      surface: 90, dpe_class: "D",
      address_confirmed_at: Time.current, address_source: "manuel"
    )
    # Sur le territoire + DRAFT → NON compté (pas encore passé par le pipeline).
    Property.create!(
      address: "3", city: "Nancy", zipcode: "54000",
      claim_token: SecureRandom.hex(16),
      code_insee: "54395", status: :draft
    )
    # Sur le territoire + ANALYZING → NON compté.
    Property.create!(
      address: "4", city: "Nancy", zipcode: "54000",
      claim_token: SecureRandom.hex(16),
      code_insee: "54395", status: :analyzing
    )
    # HORS territoire + analyzed → NON compté.
    Property.create!(
      address: "5", city: "Paris", zipcode: "75001",
      claim_token: SecureRandom.hex(16),
      code_insee: "75101", status: :analyzed
    )

    get "/collectivites/grand-nancy"
    assert_response :success

    node = css_select("#count-biens").first
    assert node
    assert_equal "2", node["data-count"],
      "Doit compter 2 biens (analyzed + published sur les INSEE couverts). Reçu : #{node["data-count"]}"
  end

  test "compteur biens : zéro par défaut si aucun bien" do
    setup_grand_nancy
    get "/collectivites/grand-nancy"
    assert_equal "0", css_select("#count-biens").first["data-count"]
  end

  # ── C5 : branding visuel + CTA vers formulaire ────────────────────────

  test "bandeau utilise primary_color de la collectivité" do
    setup_grand_nancy
    get "/collectivites/grand-nancy"
    # La primary_color apparaît dans le style inline du bandeau et du CTA.
    assert_match(/#0066a1/, response.body,
      "primary_color (#0066a1) doit apparaître dans le rendu — branding EPCI")
  end

  test "welcome_text rendu quand présent" do
    setup_grand_nancy
    get "/collectivites/grand-nancy"
    assert_select "#welcome-text"
    assert_match "Bienvenue", response.body
  end

  test "logo pas attaché → initiales rendues sur fond blanc en fallback" do
    setup_grand_nancy
    get "/collectivites/grand-nancy"
    assert_select "#collectivite-initiales", { count: 1 },
      "Fallback initiales quand aucun logo attaché (permet la démo sans logo officiel)"
    assert_select "#collectivite-logo", { count: 0 }
    # Initiales : "Métropole du Grand Nancy" → "MDGN"
    assert_match "MDGN", response.body
  end

  test "CTA link pointe vers /properties/new?collectivite=grand-nancy" do
    setup_grand_nancy
    get "/collectivites/grand-nancy"
    cta = css_select("a#cta-new-property").first
    assert cta, "CTA 'Commencer' doit exister"
    assert_equal new_property_path(collectivite: "grand-nancy"), cta["href"],
      "Le CTA doit pré-paramétrer le formulaire avec le slug (rattachement C6)"
  end

  # ── C7 : SEO / partage social ─────────────────────────────────────────

  test "portail : title HTML contient le nom de la collectivité" do
    setup_grand_nancy
    get "/collectivites/grand-nancy"
    title = css_select("title").first
    assert title
    assert_match "Métropole du Grand Nancy", title.text
    assert_match "Lauze", title.text, "Garde 'Lauze' pour la reconnaissance de marque"
  end

  test "portail : meta description = welcome_text (partage social)" do
    setup_grand_nancy
    get "/collectivites/grand-nancy"
    assert_select "meta[name='description'][content*='Bienvenue']"
  end

  test "portail sans logo attaché : pas de meta og:image (fallback layout)" do
    setup_grand_nancy
    get "/collectivites/grand-nancy"
    # Aucun logo attaché → pas d'og:image spécifique. Le partage social
    # tombera sur les defaults du site (favicon, etc.).
    assert_select "meta[property='og:image']", { count: 0 }
  end

  # ── Contenu adressé à l'HABITANT (pas au décideur EPCI) ───────────────

  test "portail : titre de la section = 'Ce que Lauze vous apporte' (audience habitant)" do
    setup_grand_nancy
    get "/collectivites/grand-nancy"
    assert_response :success
    assert_match(/Ce que Lauze vous apporte/, response.body,
      "Le titre habitant doit remplacer l'ancien 'Ce que Lauze fait pour votre territoire'")
    refute_match(/Ce que Lauze fait pour votre territoire/, response.body,
      "L'ancien titre (audience décideur) ne doit plus apparaître sur le portail")
  end

  test "portail : promesse habitant — aides de la collectivité s'ajoutent aux dispositifs nationaux" do
    setup_grand_nancy
    get "/collectivites/grand-nancy"
    assert_match(/Les aides de Métropole du Grand Nancy s'ajoutent/, response.body,
      "Le nom de la collectivité doit être interpolé dans le pitch aides (colonne 01)")
    assert_match(/MaPrimeRénov'/, response.body)
    assert_match(/CEE/, response.body)
    assert_match(/éco-PTZ/, response.body)
    assert_match(/reste à charge/, response.body)
  end

  test "portail : promesse habitant — parcours simple, sans compte obligatoire" do
    setup_grand_nancy
    get "/collectivites/grand-nancy"
    assert_match(/Déposez votre DPE/, response.body)
    assert_match(/sans création de compte obligatoire/, response.body)
  end

  test "portail : promesse habitant — pièces supprimées, données non transmises" do
    setup_grand_nancy
    get "/collectivites/grand-nancy"
    assert_match(/pièces .*supprimées après l'analyse/, response.body,
      "Reprend l'engagement déjà présent sur /properties/new")
    assert_match(/jamais transmises sans votre accord/, response.body)
  end

  test "portail : les libellés du DISCOURS DÉCIDEUR ont été retirés" do
    setup_grand_nancy
    get "/collectivites/grand-nancy"
    # Vocabulaire élu/EPCI n'a rien à faire sur une page destinée à
    # l'habitant. Ces phrases restent OK sur /collectivites marketing.
    refute_match(/Vos dispositifs locaux/, response.body,
      "Wording décideur — n'a pas sa place sur le portail habitant")
    refute_match(/sans appel à votre service/, response.body,
      "Wording décideur — présuppose le lecteur = agent EPCI")
    refute_match(/piloter votre programme rénovation/i, response.body,
      "Wording décideur — présuppose le lecteur = élu")
    refute_match(/tableau de bord territorial/i, response.body,
      "Promesse pilotage — reste sur /collectivites, pas ici")
    refute_match(/Vos statistiques/, response.body,
      "Wording décideur — 'vos statistiques' vise l'EPCI, pas l'habitant")
  end

  test "portail : compteur adressé à l'habitant (label + légende)" do
    setup_grand_nancy
    get "/collectivites/grand-nancy"
    # Nouveau label : "Près de chez vous" (habitant), plus "Usage sur
    # votre territoire" (décideur).
    assert_match(/Près de chez vous/i, response.body)
    refute_match(/Usage sur votre territoire/i, response.body)
    # Nouvelle légende : "biens déjà analysés par des habitants"
    # (plus "depuis Lauze", trop générique et froid).
    assert_match(/biens déjà analysés\s+par des habitants/i, response.body)
    refute_match(/biens analysés\s+depuis Lauze/i, response.body)
  end

  # ── Bande de réassurance en pied de portail ──────────────────────────

  test "portail : bande de réassurance présente avec les 3 engagements textuels" do
    setup_grand_nancy
    get "/collectivites/grand-nancy"
    assert_select "section#portail-reassurance", { count: 1 },
      "La bande de réassurance en pied doit exister — signal de garantie pour l'habitant"
    body = response.body
    assert_match(/Sans appel commercial/, body)
    assert_match(/Documents supprimés après analyse/, body)
    assert_match(/Données jamais transmises sans accord/, body)
  end

  test "portail : primary_color paramétrise plusieurs accents (bandeau + compteur + cartes)" do
    # Test avec une couleur non-standard pour prouver que la mise en forme
    # est bien paramétrée (pas juste belle pour le bleu Grand Nancy).
    Collectivite.create!(
      name:          "Communauté Urbaine du Test",
      slug:          "test-cu",
      primary_color: "#a83279",
      welcome_text:  "Bonjour",
      insee_codes:   %w[54001],
      active:        true
    )
    get "/collectivites/test-cu"
    assert_response :success
    # La couleur doit apparaître au moins sur : bandeau (background), compteur
    # (nombre coloré), CTA (background), et cartes propositions (bg + border).
    # 5 occurrences ~ marque de fond que le thème est vraiment paramétré.
    assert_operator response.body.scan(/#a83279/i).size, :>=, 5,
      "primary_color doit apparaître dans plusieurs accents visuels — bandeau, compteur, CTA, cartes"
  end

  # ── Non-régression du parcours public (sans slug) ─────────────────────

  test "GET / (home) rend toujours 'Lauze' comme title (fallback layout inchangé)" do
    get "/"
    assert_select "title", "Lauze"
  end

  test "GET /properties/new sans slug : parcours nominal inchangé, aucun rattachement" do
    get "/properties/new"
    assert_response :success
    assert_select "input[type=hidden][name='property[collectivite_id]']", { count: 0 }
  end
end
