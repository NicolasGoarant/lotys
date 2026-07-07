require "test_helper"

# ═══════════════════════════════════════════════════════════════════════
#   Position du lot — bandeau de confirmation + action confirm_position_lot
#
#   Pour un appartement, la position dans l'immeuble (dernier étage /
#   étage intermédiaire / RDC) détermine quelles parois donnent sur
#   l'extérieur. Sans ce champ, la matrice DPE compte des déperditions
#   fictives (diag 07/07 — toit fictif = 33 % du GV initial d'un lot
#   mitoyen).
#
#   Cette suite vérifie :
#     1. Le bandeau s'affiche pour un appartement non confirmé (avec ou
#        sans détection LLM préalable).
#     2. Il ne s'affiche PAS pour une maison (champ non applicable).
#     3. Il ne s'affiche PAS une fois position_lot_confirmed_at posé.
#     4. POST confirm_position_lot avec une valeur valide pose
#        position_lot + position_lot_confirmed_at et redirige avec notice.
#     5. Valeur hors whitelist → refusée, alerte, rien n'est écrit.
#     6. Un visiteur random (pas propriétaire, pas claimant) ne peut PAS
#        confirmer un lot qui ne lui appartient pas.
# ═══════════════════════════════════════════════════════════════════════
class PropertyConfirmPositionLotTest < ActionDispatch::IntegrationTest
  CLAIM_COOKIE = ClaimToken::CLAIM_COOKIE
  TOKEN        = "JETON_CONFIRM_POSITION_LOT_TEST"

  setup do
    set_signed_cookie(CLAIM_COOKIE, TOKEN)
  end

  def appartement_analyse(position_lot_detected: nil, position_lot_confirmed_at: nil)
    p = Property.new(
      claim_token:       TOKEN,
      address:           "5 rue des Ombelles",
      city:              "Villers-lès-Nancy",
      zipcode:           "54600",
      surface:           72,
      construction_year: 1965,
      property_type:     "appartement",
      dpe_class:         "E",
      energie_chauffage: "gaz",
      is_copropriete:    true,
      status:            :analyzed
    )
    p.save!
    p.update_columns(
      position_lot_detected:     position_lot_detected,
      position_lot_confirmed_at: position_lot_confirmed_at
    ) if position_lot_detected || position_lot_confirmed_at
    p
  end

  def maison_analysee
    p = Property.new(
      claim_token:       TOKEN,
      address:           "14 rue des Tilleuls",
      city:              "Vandœuvre-lès-Nancy",
      zipcode:           "54500",
      surface:           95,
      construction_year: 1962,
      property_type:     "maison",
      dpe_class:         "F",
      energie_chauffage: "gaz",
      status:            :analyzed
    )
    p.save!
    p
  end

  # ─── 1. Bandeau affiché pour un appartement non confirmé ─────────────
  test "bandeau affiché pour un appartement (détection présente)" do
    p = appartement_analyse(position_lot_detected: "etage_intermediaire")
    get property_path(p)
    assert_response :success
    assert_select "#confirm-position-lot", { count: 1 },
      "Un appartement non confirmé doit voir le bandeau — obtenu : absent"
    # Détection pré-remplie sur le radio correspondant.
    assert_select "#confirm-position-lot input[type=radio][value=etage_intermediaire][checked]",
      { count: 1 },
      "Le radio correspondant à position_lot_detected doit être pré-coché."
  end

  test "bandeau affiché même SANS détection LLM (radio vide)" do
    p = appartement_analyse
    get property_path(p)
    assert_response :success
    assert_select "#confirm-position-lot", { count: 1 }
    # Aucun radio pré-coché.
    assert_select "#confirm-position-lot input[type=radio][checked]", { count: 0 },
      "Sans détection, aucun radio ne doit être coché par défaut."
  end

  # ─── 2. Maison → pas de bandeau ──────────────────────────────────────
  test "maison : le bandeau n'est PAS affiché (champ non applicable)" do
    p = maison_analysee
    get property_path(p)
    assert_response :success
    assert_select "#confirm-position-lot", { count: 0 },
      "Une maison n'a pas de position de lot — le bandeau ne doit pas apparaître."
  end

  # ─── 3. Une fois confirmé, plus de bandeau ────────────────────────────
  test "bandeau retiré une fois position_lot_confirmed_at posé" do
    p = appartement_analyse(
      position_lot_detected:     "dernier_etage",
      position_lot_confirmed_at: 1.hour.ago
    )
    p.update_columns(position_lot: "dernier_etage")
    get property_path(p)
    assert_response :success
    assert_select "#confirm-position-lot", { count: 0 },
      "position_lot_confirmed_at posé → l'utilisateur a déjà tranché, plus de bandeau."
  end

  # ─── 4. Confirmation avec valeur valide ──────────────────────────────
  test "POST confirm_position_lot avec 'rdc' → pose position_lot + confirmed_at + redirect notice" do
    p = appartement_analyse(position_lot_detected: "etage_intermediaire")

    assert_nil p.position_lot
    assert_nil p.position_lot_confirmed_at

    post confirm_position_lot_property_path(p),
         params: { property: { position_lot: "rdc" } }

    assert_redirected_to property_path(p)
    follow_redirect!
    assert_response :success

    p.reload
    assert_equal "rdc", p.position_lot,
      "position_lot (valeur de vérité) doit être posée par le controller."
    assert_not_nil p.position_lot_confirmed_at,
      "position_lot_confirmed_at doit être posé pour retirer le bandeau."
    # Détecté d'origine préservé (piste d'audit).
    assert_equal "etage_intermediaire", p.position_lot_detected,
      "position_lot_detected doit rester intact — c'est une piste d'audit " \
      "(ce que le LLM avait proposé)."
  end

  # ─── 5. Valeur hors whitelist → refusée ──────────────────────────────
  test "POST avec position_lot hors whitelist → alerte, rien n'est écrit" do
    p = appartement_analyse

    post confirm_position_lot_property_path(p),
         params: { property: { position_lot: "1er_etage" } }

    assert_redirected_to property_path(p)
    p.reload
    assert_nil p.position_lot,           "Aucune écriture pour une valeur hors whitelist."
    assert_nil p.position_lot_confirmed_at
  end

  test "POST sans paramètre position_lot → alerte, rien n'est écrit" do
    p = appartement_analyse

    post confirm_position_lot_property_path(p),
         params: { property: {} }

    assert_redirected_to property_path(p)
    p.reload
    assert_nil p.position_lot
    assert_nil p.position_lot_confirmed_at
  end

  # ─── 6. Refus quand l'utilisateur n'est ni owner ni claimant ─────────
  test "visiteur random (cookie claim_token absent) → refusé par set_property_for_confirm" do
    p = appartement_analyse

    # On efface le cookie claim_token de la session courante.
    reset!
    post confirm_position_lot_property_path(p),
         params: { property: { position_lot: "rdc" } }

    # set_property_for_confirm redirige vers root avec alerte (302),
    # jamais un 403 — cf. rapport diag 07/07.
    assert_response :redirect
    p.reload
    assert_nil p.position_lot,
      "Un visiteur sans claim_token n'a pas le droit d'écrire sur ce bien."
  end

  private

  # Helper récurrent dans la suite (cf. orphan_claim_show_test.rb et
  # user_confirmation_auto_signin_test.rb) — pas de méthode d'aide
  # partagée à ce stade, on inline.
  def set_signed_cookie(name, value)
    request = ActionDispatch::TestRequest.create
    jar     = ActionDispatch::Cookies::CookieJar.build(request, cookies.to_hash)
    jar.signed[name] = value
    cookies[name.to_s] = jar[name.to_s]
  end
end
