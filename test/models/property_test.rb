require "test_helper"

# Tests modèle Property — invariant de rattachement.
#
# Une Property doit être SOIT possédée (user_id présent), SOIT revendicable
# (claim_token présent). On vérifie les trois cas canoniques avec
# Property.new (pas de save, pas de DB) — les validations du modèle
# tournent quand même via valid?.
class PropertyTest < ActiveSupport::TestCase
  # Defaults minimaux pour passer les validations indépendantes (address,
  # city, zipcode, format zipcode). Les tests ne touchent qu'à user_id et
  # claim_token, le reste est neutralisé par ces valeurs constantes.
  def base_attrs
    {
      address: "14 rue des Tilleuls",
      city:    "Vandœuvre-lès-Nancy",
      zipcode: "54500"
    }
  end

  def build_user
    # Devise :validatable exige email + password ≥ 6 caractères. Pas de
    # save() : l'invariant rattachable se vérifie sur User en mémoire car
    # belongs_to :user, optional: true accepte un User non persisté.
    User.new(email: "test-#{SecureRandom.hex(4)}@example.com", password: "azerty123")
  end

  test "bien possédé (user présent, claim_token absent) est valide" do
    property = Property.new(base_attrs.merge(user: build_user))

    assert property.valid?,
           "Bien possédé devrait être valide, reçu errors=#{property.errors.full_messages.inspect}"
  end

  test "bien orphelin (user nil, claim_token présent) est valide" do
    property = Property.new(base_attrs.merge(user: nil, claim_token: SecureRandom.uuid))

    assert property.valid?,
           "Bien orphelin avec jeton devrait être valide, reçu errors=#{property.errors.full_messages.inspect}"
  end

  test "bien ni possédé ni revendicable (user nil, claim_token nil) est INVALIDE" do
    property = Property.new(base_attrs.merge(user: nil, claim_token: nil))

    assert_not property.valid?,
               "Bien sans user NI claim_token devrait être refusé"
    assert property.errors[:base].any? { |msg| msg.include?("rattaché") },
           "L'erreur doit porter sur :base avec un message parlant de rattachement, reçu : #{property.errors[:base].inspect}"
  end

  # ──────────────────────────────────────────────────────────────────────
  # Énergie de chauffage : champ typé + source de capture
  # ──────────────────────────────────────────────────────────────────────

  # Helper : Property persistée minimale (claim_token suffit pour rattachable)
  def build_persisted_property
    Property.create!(base_attrs.merge(claim_token: SecureRandom.uuid))
  end

  test "energie_chauffage accepte les 5 énergies du moteur + :inconnue" do
    p = build_persisted_property
    %w[gaz fioul electricite bois pac inconnue].each do |e|
      assert_nothing_raised { p.energie_chauffage = e }
      assert p.save, "energie=#{e} devrait être enregistrable : #{p.errors.full_messages}"
    end
  end

  test "energie_chauffage rejette une valeur inconnue (Rails enum lève ArgumentError)" do
    p = Property.new(base_attrs.merge(claim_token: SecureRandom.uuid))
    assert_raises(ArgumentError) { p.energie_chauffage = "gaz_naturel_legacy" }
  end

  test "energie_chauffage_source accepte les 5 sources prévues" do
    p = build_persisted_property
    %w[extrait_dpe extrait_description deduit confirme_utilisateur inconnue].each do |s|
      assert_nothing_raised { p.energie_chauffage_source = s }
      assert p.save
    end
  end

  test "energie_chauffage par défaut = :inconnue (migration default + null: false)" do
    p = build_persisted_property
    assert_equal "inconnue", p.energie_chauffage
    assert_equal "inconnue", p.energie_chauffage_source
  end

  # ── Hiérarchie de confiance ────────────────────────────────────────────
  test "upgrade_energie_source? : :extrait_description > :inconnue" do
    assert Property.upgrade_energie_source?(nil,        "extrait_description")
    assert Property.upgrade_energie_source?("inconnue", "extrait_description")
  end

  test "upgrade_energie_source? : :deduit > :inconnue" do
    assert Property.upgrade_energie_source?("inconnue", "deduit")
  end

  test "upgrade_energie_source? : :extrait_description > :deduit (extrait JAMAIS écrasé par déduit)" do
    assert Property.upgrade_energie_source?("deduit", "extrait_description")
    refute Property.upgrade_energie_source?("extrait_description", "deduit"),
      ":extrait_description ne doit JAMAIS être écrasé par :deduit (proxy fioul)"
  end

  test "upgrade_energie_source? : :extrait_dpe > :extrait_description (DPE plus autoritaire)" do
    assert Property.upgrade_energie_source?("extrait_description", "extrait_dpe")
    refute Property.upgrade_energie_source?("extrait_dpe", "extrait_description")
  end

  test "upgrade_energie_source? : :confirme_utilisateur au sommet" do
    %w[inconnue deduit extrait_description extrait_dpe].each do |inferieure|
      assert Property.upgrade_energie_source?(inferieure, "confirme_utilisateur"),
        "confirme_utilisateur doit pouvoir écraser #{inferieure}"
      refute Property.upgrade_energie_source?("confirme_utilisateur", inferieure),
        "confirme_utilisateur ne doit PAS être écrasable par #{inferieure}"
    end
  end

  test "upgrade_energie_source? : même source → false (pas de re-écriture inutile)" do
    refute Property.upgrade_energie_source?("deduit", "deduit")
    refute Property.upgrade_energie_source?("extrait_description", "extrait_description")
  end

  # ── Proxy fioul depuis equipements_selection["depose_fioul"] ───────────
  test "proxy fioul : depose_fioul=true + énergie :inconnue → :fioul / :deduit" do
    p = build_persisted_property
    p.update!(equipements_selection: { "depose_fioul" => true })
    assert p.appliquer_proxy_fioul_depuis_equipements!
    p.reload
    assert_equal "fioul",  p.energie_chauffage
    assert_equal "deduit", p.energie_chauffage_source
  end

  test "proxy fioul : N'écrase PAS un :extrait_description (priorité respectée)" do
    p = build_persisted_property
    p.update!(
      energie_chauffage: "gaz",
      energie_chauffage_source: "extrait_description",
      equipements_selection: { "depose_fioul" => true }
    )
    refute p.appliquer_proxy_fioul_depuis_equipements!,
      "Le proxy doit retourner false sans toucher à un :extrait_description"
    p.reload
    assert_equal "gaz",                 p.energie_chauffage
    assert_equal "extrait_description", p.energie_chauffage_source
  end

  test "proxy fioul : depose_fioul=false → no-op" do
    p = build_persisted_property
    p.update!(equipements_selection: { "depose_fioul" => false })
    refute p.appliquer_proxy_fioul_depuis_equipements!
    p.reload
    assert_equal "inconnue", p.energie_chauffage
  end

  test "proxy fioul : depose_fioul absent → no-op" do
    p = build_persisted_property
    p.update!(equipements_selection: {})
    refute p.appliquer_proxy_fioul_depuis_equipements!
    p.reload
    assert_equal "inconnue", p.energie_chauffage
  end
end
