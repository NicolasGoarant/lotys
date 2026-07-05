require "test_helper"

# Tests modèle Collectivite (feature portail EPCI).
class CollectiviteTest < ActiveSupport::TestCase
  def base_attrs
    {
      name:          "Métropole du Grand Nancy",
      slug:          "grand-nancy",
      primary_color: "#0066a1",
      welcome_text:  "Bienvenue habitants du Grand Nancy",
      insee_codes:   %w[54395 54547],
      active:        true
    }
  end

  # ── Validations ───────────────────────────────────────────────────────

  test "avec tous les attributs valides → valide" do
    assert Collectivite.new(base_attrs).valid?
  end

  test "name requis" do
    c = Collectivite.new(base_attrs.merge(name: nil))
    refute c.valid?
    assert c.errors[:name].any?
  end

  test "slug requis" do
    c = Collectivite.new(base_attrs.merge(slug: nil))
    refute c.valid?
    assert c.errors[:slug].any?
  end

  test "slug doit être kebab-case (a-z, 0-9, tirets)" do
    refute Collectivite.new(base_attrs.merge(slug: "Grand Nancy")).valid?,   "espaces refusés"
    refute Collectivite.new(base_attrs.merge(slug: "GRAND-NANCY")).valid?,   "majuscules refusées"
    refute Collectivite.new(base_attrs.merge(slug: "grand_nancy")).valid?,   "underscore refusé"
    refute Collectivite.new(base_attrs.merge(slug: "-grand-nancy")).valid?,  "tiret initial refusé"
    refute Collectivite.new(base_attrs.merge(slug: "grand-nancy-")).valid?,  "tiret final refusé"
    assert Collectivite.new(base_attrs.merge(slug: "grand-nancy")).valid?,   "kebab-case valide"
    assert Collectivite.new(base_attrs.merge(slug: "alec-54")).valid?,       "chiffres et tiret OK"
  end

  test "slug unique" do
    Collectivite.create!(base_attrs)
    duplicate = Collectivite.new(base_attrs.merge(name: "Autre"))
    refute duplicate.valid?
    assert duplicate.errors[:slug].any?
  end

  test "primary_color doit être hex #RRGGBB" do
    refute Collectivite.new(base_attrs.merge(primary_color: "0066a1")).valid?,   "manque #"
    refute Collectivite.new(base_attrs.merge(primary_color: "#0066a")).valid?,   "5 chiffres"
    refute Collectivite.new(base_attrs.merge(primary_color: "#0066a1ff")).valid?, "8 chiffres (alpha) refusé"
    refute Collectivite.new(base_attrs.merge(primary_color: "#zzzzzz")).valid?,  "hex invalide"
    assert Collectivite.new(base_attrs.merge(primary_color: "#0066a1")).valid?
    assert Collectivite.new(base_attrs.merge(primary_color: "#FFF000")).valid?
  end

  test "insee_codes doit contenir uniquement des codes 5 chiffres" do
    refute Collectivite.new(base_attrs.merge(insee_codes: %w[54395 5459])).valid?,  "code 4 chiffres refusé"
    refute Collectivite.new(base_attrs.merge(insee_codes: %w[54395 abc])).valid?,   "non-numérique refusé"
    refute Collectivite.new(base_attrs.merge(insee_codes: %w[54395 543951])).valid?, "6 chiffres refusés"
    assert Collectivite.new(base_attrs.merge(insee_codes: %w[54395 54547])).valid?
  end

  test "insee_codes vide autorisé (config par défaut)" do
    assert Collectivite.new(base_attrs.merge(insee_codes: [])).valid?
  end

  # ── Scopes ────────────────────────────────────────────────────────────

  test "scope active ne remonte que les collectivités actives" do
    actif  = Collectivite.create!(base_attrs)
    inactif = Collectivite.create!(base_attrs.merge(slug: "eteinte", active: false))

    assert_includes    Collectivite.active, actif
    refute_includes    Collectivite.active, inactif
  end

  test "scope by_slug retrouve par slug" do
    c = Collectivite.create!(base_attrs)
    assert_equal [c], Collectivite.by_slug("grand-nancy").to_a
  end

  # ── covers_insee? ─────────────────────────────────────────────────────

  test "covers_insee? true quand code présent dans la liste" do
    c = Collectivite.new(base_attrs)
    assert c.covers_insee?("54395")
    assert c.covers_insee?("54547")
  end

  test "covers_insee? false quand code absent" do
    c = Collectivite.new(base_attrs)
    refute c.covers_insee?("75001")
    refute c.covers_insee?("54999")
  end

  test "covers_insee? false quand code nil ou blank (ne présume pas)" do
    c = Collectivite.new(base_attrs)
    refute c.covers_insee?(nil),  "nil → false, pas d'appartenance présumée"
    refute c.covers_insee?(""),   "blank → false"
    refute c.covers_insee?("   "), "espaces → false"
  end

  # ── initiales ─────────────────────────────────────────────────────────

  test "initiales avec plusieurs mots → première lettre de chaque, max 4" do
    c = Collectivite.new(base_attrs.merge(name: "Métropole du Grand Nancy"))
    assert_equal "MDGN", c.initiales
  end

  test "initiales avec un seul mot → 4 premières lettres majuscules" do
    c = Collectivite.new(base_attrs.merge(name: "ALEC"))
    assert_equal "ALEC", c.initiales
  end

  test "initiales avec un mot long → tronqué à 4 caractères" do
    c = Collectivite.new(base_attrs.merge(name: "Communauté"))
    assert_equal "COMM", c.initiales
  end

  # ── Association avec Property ─────────────────────────────────────────

  test "Property.belongs_to :collectivite, optional: true" do
    c = Collectivite.create!(base_attrs)
    p = Property.create!(
      address:     "12 rue du Test",
      city:        "Nancy",
      zipcode:     "54000",
      claim_token: SecureRandom.hex(16),
      collectivite: c
    )
    assert_equal c, p.collectivite
    assert_includes c.properties, p
  end

  test "Property sans collectivite reste valide (parcours public standard)" do
    p = Property.new(
      address:     "12 rue du Test",
      city:        "Nancy",
      zipcode:     "54000",
      claim_token: SecureRandom.hex(16)
    )
    assert p.valid?, "Un bien sans rattachement doit rester valide (parcours nominal) : #{p.errors.full_messages.inspect}"
  end

  test "dépendance nullify : supprimer une collectivité met à jour ses biens" do
    c = Collectivite.create!(base_attrs)
    p = Property.create!(
      address:     "12 rue du Test",
      city:        "Nancy",
      zipcode:     "54000",
      claim_token: SecureRandom.hex(16),
      collectivite: c
    )

    c.destroy
    p.reload
    assert_nil p.collectivite_id, "Bien conservé, collectivite_id reset à NULL"
    assert p.persisted?
  end
end
