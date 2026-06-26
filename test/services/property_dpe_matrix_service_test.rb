require "test_helper"

# Tests de PropertyDpeMatrixService — pré-calcul des 128 combinaisons des
# 7 gestes sur un Property donné. Future source unique de la jauge à la
# place de DPE_IMPACT (consommation au Temps 3b-2 ; cette session ne fait
# que produire et exposer la table).
#
# Périmètre :
#   - Reconstruit etat_initial depuis Property (énergie typée, isolation
#     via grille §3bis si pas de donnée réelle, zone via zipcode).
#   - Appelle PropertyDpeService pour chaque sous-ensemble des 7 gestes.
#   - Calcule un classement de priorité réel SPÉCIFIQUE au bien.
#   - Marque etat_incertain quand la source de l'état est :deduit/:inconnue.

class PropertyDpeMatrixServiceTest < ActiveSupport::TestCase
  # ── Helpers — biens en mémoire, pas de save() requis pour la matrice ─────
  def base_attrs
    {
      address:     "1 rue de test",
      city:        "Nancy",
      zipcode:     "54000",
      claim_token: SecureRandom.uuid
    }
  end

  # Bien oracle Lauze ID 107 : Tilleuls, 1962, gaz extrait, classé F réel.
  def maison_oracle_tilleuls
    Property.new(base_attrs.merge(
      address:                  "14 rue des Tilleuls",
      city:                     "Vandœuvre-lès-Nancy",
      zipcode:                  "54500",
      surface:                  95,
      construction_year:        1962,
      property_type:            "maison",
      dpe_class:                "F",
      energie_chauffage:        "gaz",
      energie_chauffage_source: "extrait_description"
    ))
  end

  # Bien ID 69 : 1995, énergie inconnue, classé D réel.
  def maison_1995_inconnue
    Property.new(base_attrs.merge(
      surface:                  82,
      construction_year:        1995,
      property_type:            "maison",
      dpe_class:                "D",
      energie_chauffage:        "inconnue",
      energie_chauffage_source: "inconnue"
    ))
  end

  # Bien fioul 1970 — pour tester la priorité « chauffage parmi top ».
  def maison_fioul_1970
    Property.new(base_attrs.merge(
      surface:                  100,
      construction_year:        1970,
      property_type:            "maison",
      energie_chauffage:        "fioul",
      energie_chauffage_source: "extrait_description"
    ))
  end

  # Bien PAC déjà installée — sur ce bien, le geste « chauffage » rapporte
  # zéro (PAC → PAC), donc l'isolation prime forcément.
  def maison_pac_non_isolee
    Property.new(base_attrs.merge(
      surface:                  100,
      construction_year:        1970,
      property_type:            "maison",
      energie_chauffage:        "pac",
      energie_chauffage_source: "extrait_description"
    ))
  end

  # ────────────────────────────────────────────────────────────────────────
  # 1. Combinaison vide = classe de l'état initial
  # ────────────────────────────────────────────────────────────────────────

  test "combinaison vide donne la classe de l'état initial (Tilleuls → F)" do
    r = PropertyDpeMatrixService.call(maison_oracle_tilleuls)
    classe_vide = r[:combinaisons][""][:classe]
    assert_equal "F", classe_vide,
      "Sans aucun geste, Tilleuls 1962 gaz devrait sortir en F (cohérent DPE réel ID 107)"
  end

  # ────────────────────────────────────────────────────────────────────────
  # 2. Combinaison pleine ≤ toutes les autres
  # ────────────────────────────────────────────────────────────────────────

  test "combinaison pleine (7 gestes) est meilleure ou égale à toutes les autres" do
    r = PropertyDpeMatrixService.call(maison_oracle_tilleuls)
    cle_pleine = PropertyDpeMatrixService::GESTES.sort.join(",")
    classe_pleine = r[:combinaisons][cle_pleine][:classe]
    idx = DpeEngineService::ORDRE_CLASSES
    rang_pleine = idx.index(classe_pleine)

    r[:combinaisons].each do |key, data|
      rang_autre = idx.index(data[:classe])
      assert rang_pleine <= rang_autre,
        "Combinaison « #{key.empty? ? '(vide)' : key} » sort en #{data[:classe]}, " \
        "meilleure que pleine #{classe_pleine} — viole le principe « tout coché = meilleur »"
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # 3. Monotonie : ajouter un geste ne dégrade jamais la classe atteignable
  # ────────────────────────────────────────────────────────────────────────

  test "monotonie : ajouter un geste à une combinaison ne dégrade jamais la classe" do
    r = PropertyDpeMatrixService.call(maison_oracle_tilleuls)
    gestes = PropertyDpeMatrixService::GESTES
    idx = DpeEngineService::ORDRE_CLASSES

    r[:combinaisons].each do |key, data|
      actifs   = key.split(",").reject(&:empty?)
      inactifs = gestes - actifs
      rang_actuel = idx.index(data[:classe])

      inactifs.each do |g_add|
        cle_plus = (actifs + [g_add]).sort.join(",")
        rang_plus = idx.index(r[:combinaisons][cle_plus][:classe])
        assert rang_plus <= rang_actuel,
          "Ajouter « #{g_add} » à [#{actifs.join(',')}] dégrade la classe : " \
          "#{data[:classe]} → #{r[:combinaisons][cle_plus][:classe]}"
      end
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # 4. Cohérence avec PropertyDpeService — matrice == appel direct
  # ────────────────────────────────────────────────────────────────────────

  test "cohérence : la classe en matrice == celle d'un appel direct à PropertyDpeService" do
    p      = maison_oracle_tilleuls
    matrix = PropertyDpeMatrixService.call(p)
    gestes_test = %w[isolation_murs isolation_toiture menuiseries]
    cle = gestes_test.sort.join(",")
    classe_matrix = matrix[:combinaisons][cle][:classe]

    direct = PropertyDpeService.call(
      surface:            p.surface,
      annee_construction: p.construction_year,
      zone_climatique:    :h1,
      etat_initial:       matrix[:etat_initial],
      gestes:             gestes_test
    )

    assert_equal direct[:classe_apres], classe_matrix,
      "Matrice (#{classe_matrix}) doit retourner le même résultat que PropertyDpeService direct (#{direct[:classe_apres]})"
  end

  # ────────────────────────────────────────────────────────────────────────
  # 5. Priorité des gestes — dépend du bien, pas une règle fixe
  # ────────────────────────────────────────────────────────────────────────

  test "priorité gestes — sur bien fioul, le geste chauffage figure dans le top 3" do
    r = PropertyDpeMatrixService.call(maison_fioul_1970)
    top3 = r[:priorite_gestes].first(3).map { |i| i[:code] }
    assert_includes top3, "chauffage",
      "Sur fioul, chauffage devrait dominer (×4 sur carbone + ÷3 conso). Top 3 = #{top3}"
  end

  test "priorité gestes — sur bien PAC déjà installée, chauffage rapporte zéro (isolation prime)" do
    r = PropertyDpeMatrixService.call(maison_pac_non_isolee)
    priorite = r[:priorite_gestes]
    chauffage = priorite.find { |i| i[:code] == "chauffage" }

    # PAC → PAC (énergie cible par défaut de PropertyDpeService) ⇒ aucun changement
    assert_in_delta 0.0, chauffage[:gain_ep], 0.5,
      "Geste chauffage sur bien déjà PAC ne doit pas améliorer (gain attendu ~0, obtenu #{chauffage[:gain_ep]})"

    top1 = priorite.first[:code]
    assert_includes %w[isolation_murs isolation_toiture menuiseries isolation_plancher_bas vmc], top1,
      "Top 1 sur bien PAC non isolée doit être un geste d'enveloppe (chauffage est neutre), obtenu #{top1}"
  end

  test "priorité gestes — l'ordre dépend du bien (preuve : top 1 diffère entre fioul et PAC)" do
    top_fioul = PropertyDpeMatrixService.call(maison_fioul_1970)[:priorite_gestes].first[:code]
    top_pac   = PropertyDpeMatrixService.call(maison_pac_non_isolee)[:priorite_gestes].first[:code]
    refute_equal top_fioul, top_pac,
      "Top 1 doit différer entre fioul (#{top_fioul}) et PAC (#{top_pac}) — c'est la preuve que la priorité dépend du bien, vs DPE_IMPACT qui est figée"
  end

  # ────────────────────────────────────────────────────────────────────────
  # 6. Drapeau etat_incertain
  # ────────────────────────────────────────────────────────────────────────

  test "etat_incertain = true pour un bien à énergie :inconnue" do
    r = PropertyDpeMatrixService.call(maison_1995_inconnue)
    assert r[:etat_incertain], "État doit être marqué incertain (énergie inconnue)"
    assert_equal "inconnue", r[:details_incertitude][:energie_source]
  end

  test "etat_incertain reste true même avec énergie extraite — isolation toujours déduite par grille" do
    r = PropertyDpeMatrixService.call(maison_oracle_tilleuls)
    # Tilleuls a énergie :extrait_description, mais l'isolation vient toujours
    # de la grille §3bis (pas de capture isolation cette session — dette).
    assert r[:etat_incertain], "Isolation toujours déduite = état toujours incertain à ce stade"
    assert_equal "deduit", r[:details_incertitude][:isolation_source]
  end

  # ────────────────────────────────────────────────────────────────────────
  # 7. Performance — 128 combinaisons + classement < 200 ms
  # ────────────────────────────────────────────────────────────────────────

  test "performance : 128 combinaisons + classement priorité en moins de 200 ms" do
    # Warm-up : éviter d'inclure l'autoload Ruby/Rails dans la mesure.
    PropertyDpeMatrixService.call(maison_oracle_tilleuls)

    duree_ms = 1000 * Benchmark.realtime { PropertyDpeMatrixService.call(maison_oracle_tilleuls) }
    assert duree_ms < 200,
      "Matrice doit tenir sous 200 ms — mesuré #{duree_ms.round(1)} ms"
  end
end
