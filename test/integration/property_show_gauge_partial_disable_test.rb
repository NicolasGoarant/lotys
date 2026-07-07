require "test_helper"
require "open3"
require "json"
require_relative "../support/aid_rules_helper"

# Vérifie le rendu HONNÊTE de la jauge quand la matrice DPE ne peut pas être
# calculée (surface OU année manquante), et le rendu NORMAL quand tout est
# extrait.
#
# Trois exigences testées :
#   1. Source de vérité unique — jauge et en-tête lisent @property.surface
#      et @property.construction_year.
#   2. Message d'invite dynamique — ne mentionne QUE les champs réellement
#      absents (bug : le message historique citait "surface et année" même
#      quand seule l'année manquait).
#   3. Griser UNIQUEMENT la projection — la classe DPE actuelle vient du
#      document uploadé, c'est un fait fiable ; le curseur "actuel" doit
#      rester rendu en couleur sur son segment, seule la partie projection
#      (pin cible, slider, label objectif) est désactivée.
class PropertyShowGaugePartialDisableTest < ActionDispatch::IntegrationTest
  include AidRulesHelper

  CLAIM_COOKIE = ClaimToken::CLAIM_COOKIE
  TOKEN        = "JETON_GAUGE_PARTIAL_TEST"

  setup do
    seed_aid_rules!
    set_signed_cookie(CLAIM_COOKIE, TOKEN)
  end

  # ── 1. Verrou de régression — surface + année → jauge active ──────────
  # Reproduit le scénario Malzéville : les deux champs sont extraits, la
  # jauge doit être calculable, aucun bandeau d'invite ne doit apparaître.
  test "surface + construction_year extraits → jauge active, pas de bandeau" do
    p = creer_bien(surface: 118, construction_year: 1928, dpe_class: "F")

    get property_path(p)
    assert_response :success

    assert_select "script#dpe-matrix-data", { count: 1 },
      "Avec surface ET année, la matrice DPE doit être injectée"
    refute_match(/Complétez votre dossier/, response.body,
      "Aucun bandeau d'invite quand les deux champs requis sont présents")
  end

  # ── 2a. Message dynamique — seule l'année manque ──────────────────────
  # Bug observé sur le bien Malzéville : la surface (118 m²) est extraite,
  # mais l'année (1928) reste nil car le pipeline LLM l'a manquée. Le
  # message historique cite "surface et année" — le fix doit citer
  # seulement l'année.
  test "surface OK + année nil → bandeau cite l'année SEULEMENT" do
    p = creer_bien(surface: 118, construction_year: nil, dpe_class: "F")

    get property_path(p)
    assert_response :success

    assert_match(/Complétez votre dossier/, response.body)
    assert_match(/année de construction/, response.body,
      "L'année manquante doit être citée")
    refute_match(/surface habitable/, response.body,
      "La surface étant présente, elle ne doit PAS être citée comme manquante")
  end

  # ── 2b. Message dynamique — seule la surface manque ───────────────────
  test "année OK + surface nil → bandeau cite la surface SEULEMENT" do
    p = creer_bien(surface: nil, construction_year: 1928, dpe_class: "F")

    get property_path(p)
    assert_response :success

    assert_match(/Complétez votre dossier/, response.body)
    assert_match(/surface habitable/, response.body,
      "La surface manquante doit être citée")
    refute_match(/année de construction/, response.body,
      "L'année étant présente, elle ne doit PAS être citée comme manquante")
  end

  # ── 2c. Message dynamique — les deux manquent ─────────────────────────
  test "surface nil + année nil → bandeau cite les deux" do
    p = creer_bien(surface: nil, construction_year: nil, dpe_class: "F")

    get property_path(p)
    assert_response :success

    assert_match(/surface habitable/, response.body)
    assert_match(/année de construction/, response.body)
  end

  # ── 3a. La classe actuelle reste visible sans pin rond dédié ─────────
  # Depuis le fix "pin redondant" : plus de #pin-cur. La classe DPE
  # actuelle s'affiche via DEUX signaux complémentaires :
  #   1. marqueur textuel « ▼ actuel » au-dessus du bon segment,
  #   2. segment coloré à opacité pleine (les autres à 0.4).
  # Ces deux signaux sont inconditionnels (rendus même quand la matrice
  # est absente). Le pin rond est réservé à l'objectif.
  test "année manquante → marqueur ▼ actuel + segment F opaque restent visibles" do
    p = creer_bien(surface: 118, construction_year: nil, dpe_class: "F")

    get property_path(p)
    assert_response :success

    assert_match(/▼ actuel/, response.body,
      "Le marqueur textuel « ▼ actuel » doit être présent même sans matrice")
    # Le segment "F" reste rendu et à opacité pleine (opacity:1 dans style
    # inline) — les autres segments sont à opacity:0.4. On accepte des
    # propriétés inline supplémentaires (cursor:pointer, etc.) entre
    # opacity:1 et le contenu du div.
    assert_match(/opacity:1;[^>]*>F</, response.body,
      "Le segment DPE actuel (F) doit rester à opacité pleine")
    # Verrou anti-régression du bug rendu : plus de pin rond doublon.
    assert_nil css_select("#pin-cur").first,
      "Plus de #pin-cur rond — remplacé par le marqueur textuel (fix doublon)"
  end

  # ── 3b. Griser uniquement la projection — pin cible ABSENT quand matrice nil ─
  # La projection (classe atteignable) est justement ce qui n'est pas
  # calculable. Le pin cible (#pin-tgt) et le slider ne doivent PAS être
  # rendus dans ce cas — plutôt qu'affichés greyés-mais-présents.
  test "matrice absente → pin cible (#pin-tgt) et slider NON rendus" do
    p = creer_bien(surface: 118, construction_year: nil, dpe_class: "F")

    get property_path(p)
    assert_response :success

    assert_nil css_select("#pin-tgt").first,
      "Le pin cible ne doit PAS être rendu quand la matrice ne peut pas projeter"
    assert_nil css_select("input#dpe-slider").first,
      "Le slider ne doit PAS être rendu quand la matrice est absente"
  end

  # ── 3c. Matrice présente — seul pin-tgt existe, pas de doublon ────────
  # Le pin rond est RÉSERVÉ à l'objectif. La classe actuelle reste
  # matérialisée par le marqueur textuel « ▼ actuel » + segment opaque.
  # Anti-régression : rétablir #pin-cur créerait à nouveau le doublon
  # visuel signalé en prod.
  test "matrice présente → uniquement pin-tgt (pas de #pin-cur, marqueur textuel suffit)" do
    p = creer_bien(surface: 118, construction_year: 1928, dpe_class: "F")

    get property_path(p)
    assert_response :success

    assert css_select("#pin-tgt").first,       "Pin cible présent"
    assert css_select("input#dpe-slider").first, "Slider présent"
    assert_nil css_select("#pin-cur").first,
      "Aucun pin rond doublon pour la classe actuelle — marqueur textuel suffit"
    assert_match(/▼ actuel/, response.body,
      "Le marqueur textuel « ▼ actuel » reste présent aussi avec matrice")
  end

  # ── 4a. Microtext de recalage en DOM (masqué, révélé par JS) ─────────
  # Anti-régression du bug prod où le microtexte manquait — le user disait
  # « la jauge ne répond pas ». Il doit exister au premier rendu HTML pour
  # être révélable par onSliderChange côté client. Test de PRÉSENCE et
  # d'état initial masqué (display:none).
  test "matrice présente → #dpe-recale-note en DOM, masqué initialement" do
    p = creer_bien(surface: 118, construction_year: 1928, dpe_class: "F")
    get property_path(p)
    assert_response :success

    assert_select "#dpe-recale-note", { count: 1 },
      "Le microtexte de recalage doit être présent dans le DOM au premier rendu"
    note_html = css_select("#dpe-recale-note").first.to_s
    assert_match(/display\s*:\s*none/i, note_html,
      "Le microtexte doit démarrer masqué (affiché par JS au recalage). HTML: #{note_html}")
  end

  # ── 4a-bis. Note permanente de plafonnement (bug bien 232) ──────────
  # Ajouté après le bug bien 232 : quand la meilleure classe atteignable
  # est capée (seuls 3 gestes proposés), les classes inatteignables (A/B/C
  # pour un bien E où la meilleure atteignable est D) n'affichaient rien
  # de spécial et cliquer sur "murs" en plus n'était pas ressenti comme
  # une amélioration (D → D silencieux). On rend maintenant en DOM une
  # note de plafonnement, masquée par défaut ; initShow la révèle si
  # bestAchievableIdx < CUR. Test de PRÉSENCE et d'état initial masqué.
  test "matrice présente → #dpe-plafond-note en DOM, masqué initialement" do
    p = creer_bien(surface: 118, construction_year: 1928, dpe_class: "F")
    get property_path(p)
    assert_response :success

    assert_select "#dpe-plafond-note", { count: 1 },
      "La note permanente de plafonnement doit être présente dans le DOM " \
      "au premier rendu (révélée par initShow si bestAchievableIdx < CUR)"

    note_html = css_select("#dpe-plafond-note").first.to_s
    assert_match(/display\s*:\s*none/i, note_html,
      "La note de plafonnement doit démarrer masquée (affichée par initShow " \
      "quand computeDominatedClasses détecte des classes inatteignables). HTML: #{note_html}")
    # Le placeholder [data-plafond-classe] est le hook JS qui reçoit le nom
    # de la meilleure classe atteignable au chargement — anti-régression
    # d'un renommage/suppression qui casserait initShow silencieusement.
    assert_select "#dpe-plafond-note [data-plafond-classe]", { count: 1 },
      "Le placeholder [data-plafond-classe] est nécessaire à initShow pour " \
      "injecter le nom de la classe atteignable"
  end

  # ── 4a-ter. Note de plafonnement : maison F avec toutes classes atteignables ──
  # Bug rapporté : sur une maison F où seule E était dominée (recale vers D
  # via isolation_murs, moins chère qu'isolation_toiture), l'ancien code
  # affichait « plafond D » alors qu'A est directement atteignable.
  #
  # Fix (dpe_slider_logic.js#computeBestAchievable) : la note ne se révèle
  # QUE si hasUnreachable=true. Une classe seulement dominée n'a jamais
  # rien plafonné.
  #
  # Vérification bout en bout : on récupère la matrice serveur injectée
  # dans la page, on exécute computeBestAchievable via Node avec les codes
  # rendus par la vue (data-code sur .travail-check) et les médianes
  # (data-mediane). On assert que hasUnreachable=false → le JS de la vue
  # ne révèlerait JAMAIS #dpe-plafond-note pour ce bien.
  test "maison F — computeBestAchievable sur la matrice serveur : hasUnreachable=false, pas de plafond" do
    p = creer_bien(surface: 118, construction_year: 1928, dpe_class: "F")
    get property_path(p)
    assert_response :success

    matrix_json = css_select("script#dpe-matrix-data").first.text
    matrix = JSON.parse(matrix_json)

    # Récupère les codes proposables (data-code) et coûts médians (data-mediane)
    # exactement comme le fait extractAvailableCodes / extractTravauxCosts
    # côté JS. Sur une maison hors copro, ProposableGestesService (commit 66ab2ee)
    # retourne les 7 codes canoniques.
    labels = css_select(".travail-check")
    available_codes = labels.map { |l| l["data-code"] }.compact
    costs = labels.each_with_object({}) do |l, h|
      h[l["data-code"]] = l["data-mediane"].to_i if l["data-code"]
    end
    assert_equal 7, available_codes.size,
      "Maison hors copro : les 7 gestes canoniques doivent être proposés. " \
      "Obtenu : #{available_codes.inspect}"

    # Balayage de tous les currentDpeIdx > 0 (F=5, jusque B=1) : on veut
    # que la borne « hasUnreachable=false » tienne quel que soit CUR
    # supposé — un vrai bug de séparation se manifesterait sur au moins un.
    payload = {
      currentDpeIdx:  5, # F, comme le bien
      combinaisons:   matrix["combinaisons"],
      travauxCosts:   costs,
      availableCodes: available_codes
    }.to_json
    logic_file = Rails.root.join("app/javascript/dpe_slider_logic.js").to_s
    script = <<~JS
      const { computeBestAchievable } = require(#{logic_file.inspect});
      console.log(JSON.stringify(computeBestAchievable(JSON.parse(process.argv[1]))));
    JS
    _, err_check, st_check = Open3.capture3("node", "-v")
    skip "node CLI absent du PATH du runner (#{err_check.strip})" unless st_check.success?

    out, err, st = Open3.capture3("node", "-e", script, payload)
    assert st.success?, "node a échoué : #{err}"
    result = JSON.parse(out)

    assert_equal false, result["hasUnreachable"],
      "Sur une maison F avec les 7 gestes proposables et une matrice complète, " \
      "toutes les classes A→E doivent être atteignables. hasUnreachable=true " \
      "signifierait que le JS révélerait #dpe-plafond-note à tort. Obtenu : #{result.inspect}"
    # Sanity : A doit être atteignable pour une maison hors copro (128 combi
    # avec toutes les 7 gestes disponibles → au moins une combi atteint A).
    assert_operator result["bestAchievableIdx"], :<=, 4,
      "bestAchievableIdx doit être au moins E (<=4) sur une maison F pleine. Obtenu : #{result.inspect}"
  end

  # ── 4b. Hit-area slider : bottom:0 (pas top:0) ──────────────────────
  # Le parent contient AUSSI la rangée "▼ actuel" (~16px) au-dessus de la
  # track (48px). Avec top:0, le range input laissait ~16 derniers pixels
  # de la track HORS hit-area — clics sur le bas des lettres ignorés en
  # prod. Fix : bottom:0 ancre le slider en bas du parent, couvre la
  # track exactement.
  test "matrice présente → slider ancré bottom:0 pour couvrir toute la track" do
    p = creer_bien(surface: 118, construction_year: 1928, dpe_class: "F")
    get property_path(p)

    slider = css_select("input#dpe-slider").first
    assert slider, "Slider présent"
    style = slider["style"].to_s
    assert_match(/bottom\s*:\s*0/i, style,
      "Le slider doit être ancré en bas (bottom:0) — sans quoi une partie de la track " \
      "reste hors hit-area et les clics sur le bas des segments sont perdus. " \
      "Style : #{style.inspect}")
    refute_match(/top\s*:\s*0[^%]/i, style,
      "Ne PAS revenir à top:0 (bug prod hit-area)")
  end

  # ── 4c. Clic direct par segment : data-idx + pointer-events:none ────
  # Anti-régression du bug prod bien 214 : clic sur B ou E n'atteignait
  # pas la classe cliquée à cause de la mapping thumb→value du range
  # input (les segments B/E ne s'alignaient pas avec les positions
  # discrètes du thumb, elles-mêmes fonction de sa largeur).
  # Fix : chaque segment porte data-idx="0..6" et un click listener JS
  # DIRECT (initShow). Le range input est neutralisé côté souris via
  # pointer-events:none (garde focus + arrow keys pour l'accessibilité).
  test "matrice présente → chaque segment porte data-idx=0..6 (clic direct)" do
    p = creer_bien(surface: 118, construction_year: 1928, dpe_class: "F")
    get property_path(p)

    segments = css_select(".dpe-seg")
    assert_equal 7, segments.size, "Sept segments A→G attendus"
    idxs = segments.map { |s| s["data-idx"] }
    assert_equal %w[0 1 2 3 4 5 6], idxs,
      "Chaque segment doit porter data-idx=0..6 dans l'ordre A→G " \
      "pour que le click listener JS le lise et invoque onSliderChange(idx). " \
      "Obtenu : #{idxs.inspect}"
  end

  test "matrice présente → slider neutralisé côté souris (pointer-events:none)" do
    p = creer_bien(surface: 118, construction_year: 1928, dpe_class: "F")
    get property_path(p)

    slider = css_select("input#dpe-slider").first
    style = slider["style"].to_s
    assert_match(/pointer-events\s*:\s*none/i, style,
      "Le range input doit être neutralisé côté souris — sans quoi il capture " \
      "les clics et les mappe géométriquement (bug prod). Style : #{style.inspect}")
    # Focus keyboard préservé via aria-label (bonne pratique quand le
    # visuel est masqué à l'utilisateur voyant).
    assert slider["aria-label"], "aria-label présent pour l'accessibilité clavier"
  end

  private

  def set_signed_cookie(name, value)
    request = ActionDispatch::TestRequest.create
    jar     = ActionDispatch::Cookies::CookieJar.build(request, cookies.to_hash)
    jar.signed[name] = value
    cookies[name.to_s] = jar[name.to_s]
  end

  def creer_bien(attrs)
    Property.create!({
      address:        "12 rue du Haut-Rivage",
      city:           "Malzéville",
      zipcode:        "54220",
      property_type:  "maison",
      status:         :analyzed,
      claim_token:    TOKEN,
      household_size: 3,
      rfr:            25_000,
      dpe_target:     nil
    }.merge(attrs))
  end
end
