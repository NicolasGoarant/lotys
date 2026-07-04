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

  # ──────────────────────────────────────────────────────────────────────
  # C2 — Validation substitution : adresse OU documents à la création
  # ──────────────────────────────────────────────────────────────────────
  # Le formulaire public peut être soumis sans adresse si l'utilisateur
  # fournit au moins un document (DPE, titre, facture). Quatre cas :
  #   (address+city+zipcode)   sans docs         → VALIDE
  #   sans adresse              avec upload      → VALIDE (documents_pending)
  #   sans adresse              docs persistés   → VALIDE (bien existant)
  #   sans adresse              sans upload      → INVALIDE (message clair)

  test "adresse complète, aucun document → valide" do
    property = Property.new(base_attrs.merge(claim_token: SecureRandom.uuid))
    assert property.valid?,
      "Adresse complète devrait suffire, reçu : #{property.errors.full_messages.inspect}"
  end

  test "adresse vide, documents_pending signalé par le controller → valide" do
    property = Property.new(claim_token: SecureRandom.uuid)
    property.documents_pending = true
    assert property.valid?,
      "Documents joints devraient suffire, reçu : #{property.errors.full_messages.inspect}"
  end

  test "adresse vide, bien persisté avec un document rattaché → valide" do
    # Cas update : le bien a été créé avec docs (path substitution), la
    # revalidation ultérieure ne doit pas rejeter faute d'adresse.
    property = Property.create!(base_attrs.merge(claim_token: SecureRandom.uuid))
    property.documents.create!(document_type: :dpe, name: "dpe.pdf")
    property.update_columns(address: nil, city: nil, zipcode: nil)
    property.reload

    assert property.valid?,
      "Bien persisté avec un doc devrait rester valide, reçu : #{property.errors.full_messages.inspect}"
  end

  test "adresse vide, aucun document → INVALIDE avec message parlant" do
    property = Property.new(claim_token: SecureRandom.uuid)
    assert_not property.valid?
    assert property.errors[:base].any? { |m| m.include?("Indiquez l'adresse") && m.include?("document") },
      "L'erreur doit expliquer les deux voies (adresse OU document), reçu : #{property.errors[:base].inspect}"
  end

  test "adresse partielle (ville manquante) sans document → INVALIDE" do
    # Pas de moitié d'adresse admise : soit tout, soit rien avec docs.
    property = Property.new(
      address: "12 rue du Test",
      zipcode: "54000",
      claim_token: SecureRandom.uuid
    )
    assert_not property.valid?
  end

  test "zipcode invalide reste refusé même en présence de documents_pending" do
    # Le allow_blank sur le format n'autorise QUE l'absence — un zipcode
    # malformé reste une erreur (protège contre "monville" ou "5400" saisis
    # accidentellement).
    property = Property.new(
      address:  "12 rue du Test",
      city:     "Nancy",
      zipcode:  "5400",
      claim_token: SecureRandom.uuid
    )
    property.documents_pending = true
    assert_not property.valid?
    assert property.errors[:zipcode].any? { |m| m.include?("5 chiffres") },
      "Format zipcode doit rester validé, reçu : #{property.errors[:zipcode].inspect}"
  end

  # ── Publication conditionnée à la confirmation d'adresse ──────────────
  test "publication BLOQUÉE tant qu'address_confirmed_at est NULL" do
    p = build_persisted_property
    # Publication exige aussi surface + dpe_class (validations existantes) :
    # on les remplit pour que seule la confirmation d'adresse fasse échec.
    p.update!(surface: 95, dpe_class: "D")
    p.status = :published

    assert_not p.valid?
    assert p.errors[:base].any? { |m| m.include?("Confirmez l'adresse") },
      "Message publication attendu, reçu : #{p.errors[:base].inspect}"
  end

  test "publication AUTORISÉE quand address_confirmed_at est posé" do
    p = build_persisted_property
    p.update!(surface: 95, dpe_class: "D", address_confirmed_at: Time.current)
    p.status = :published
    assert p.valid?,
      "Confirmation posée doit débloquer la publication, reçu : #{p.errors.full_messages.inspect}"
  end

  # ── address_source contraint aux valeurs canoniques ───────────────────
  test "address_source accepte les 4 valeurs canoniques" do
    %w[dpe titre_propriete facture manuel].each do |src|
      p = Property.new(base_attrs.merge(claim_token: SecureRandom.uuid, address_source: src))
      assert p.valid?, "address_source=#{src} devrait passer, reçu : #{p.errors.full_messages.inspect}"
    end
  end

  test "address_source rejette une valeur hors liste" do
    p = Property.new(base_attrs.merge(claim_token: SecureRandom.uuid, address_source: "extranet_epci"))
    assert_not p.valid?
    assert p.errors[:address_source].present?
  end
end
