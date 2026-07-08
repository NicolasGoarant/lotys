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

  # ────────────────────────────────────────────────────────────────────────
  # 8. Restriction aux gestes proposables (via ProposableGestesService)
  # ────────────────────────────────────────────────────────────────────────
  # La matrice n'énumère que les combinaisons des gestes ACTIONNABLES
  # pour ce bien. Pour une maison, tout est proposable → 128 combi
  # comme avant (backward-compat). Pour un appartement en copro gaz
  # collectif, chauffage est exclu → 64 combi et aucune clé ne contient
  # "chauffage". Cohérence stricte avec ce que la vue affiche comme
  # cases à cocher — plus de dérive availableCodes ≠ matrice.

  # Copro gaz sans équipement individuel : ProposableGestesService retire
  # "chauffage" → la matrice passe de 128 à 64 combinaisons.
  def appartement_copro_gaz_collectif
    Property.new(base_attrs.merge(
      surface:                  72,
      construction_year:        1965,
      property_type:            "appartement",
      is_copropriete:           true,
      dpe_class:                "E",
      energie_chauffage:        "gaz",
      energie_chauffage_source: "extrait_description"
    ))
  end

  test "matrice restreinte aux gestes proposables : copro gaz collectif → 64 combi, aucune 'chauffage'" do
    r = PropertyDpeMatrixService.call(appartement_copro_gaz_collectif)
    combi = r[:combinaisons]
    # 6 gestes proposables sur 7 (chauffage exclu) → 2^6 = 64.
    assert_equal 64, combi.size,
      "Copro gaz collectif : matrice devrait être restreinte à 2^6 = 64 combi. " \
      "Obtenu #{combi.size}."
    # Aucune clé de combi ne doit contenir "chauffage" — le geste n'est
    # tout simplement plus dans l'espace d'énumération.
    fautes = combi.keys.select { |k| k.split(",").include?("chauffage") }
    assert_empty fautes,
      "Aucune combinaison ne doit inclure 'chauffage' pour un lot en copro gaz collectif. " \
      "Fautes : #{fautes.inspect}"
    # Les gestes proposables sont exposés dans meta pour la vue.
    refute_includes r.dig(:meta, :gestes_proposables), "chauffage",
      "meta[:gestes_proposables] doit refléter le filtre serveur."
  end

  test "matrice complète pour une maison — 128 combi, backward-compat" do
    r = PropertyDpeMatrixService.call(maison_oracle_tilleuls)
    assert_equal 128, r[:combinaisons].size,
      "Une maison hors copro n'exclut aucun geste : la matrice reste à 128 combi."
    assert_equal PropertyDpeMatrixService::GESTES.sort,
                 r.dig(:meta, :gestes_proposables).sort,
      "Une maison expose l'ensemble canonique dans meta[:gestes_proposables]."
  end

  # ────────────────────────────────────────────────────────────────────────
  # 9. Geste chauffe_eau câblé (bien 127 style : appartement copro E gaz)
  # ────────────────────────────────────────────────────────────────────────
  # Avant : chauffe_eau était un no-op ; chaque clé avec chauffe_eau
  # rendait strictement le même ep_m2/co2_m2 que sa jumelle sans (symptôme
  # observé sur le bien local 127 : combi vmc+murs+menuiseries et combi
  # chauffe_eau+vmc+murs+menuiseries → 124,0 EP identique). Après :
  # bascule ECS sur :pac dans le moteur, les clés avec chauffe_eau
  # descendent strictement en dessous de leurs jumelles sans.

  test "clés avec chauffe_eau descendent sous leurs jumelles sans (bien copro gaz — profil bien 127)" do
    r = PropertyDpeMatrixService.call(appartement_copro_gaz_collectif)
    combi = r[:combinaisons]
    # Toutes les clés sans chauffe_eau qui ont une jumelle avec.
    paires_verifiees = 0
    combi.keys.reject { |k| k.split(",").include?("chauffe_eau") }.each do |cle_sans|
      cle_avec = (cle_sans.split(",").reject(&:empty?) + ["chauffe_eau"]).sort.join(",")
      next unless combi[cle_avec]

      ep_sans, ep_avec   = combi[cle_sans][:ep_m2],  combi[cle_avec][:ep_m2]
      co2_sans, co2_avec = combi[cle_sans][:co2_m2], combi[cle_avec][:co2_m2]
      # Sur bien gaz : ep_avec < ep_sans (delta ~1,7) ET co2_avec < co2_sans (delta ~3).
      assert_operator ep_avec, :<, ep_sans,
        "chauffe_eau doit strict réduire ep_m2 " \
        "(clé sans=#{cle_sans.inspect} avec=#{cle_avec.inspect} : #{ep_sans} → #{ep_avec})"
      assert_operator co2_avec, :<, co2_sans,
        "chauffe_eau doit strict réduire co2_m2 sur bien gaz " \
        "(clé sans=#{cle_sans.inspect} : #{co2_sans} → #{co2_avec})"
      paires_verifiees += 1
    end
    assert_operator paires_verifiees, :>, 0,
      "Aucune paire jumelée trouvée — chauffe_eau n'est plus dans la matrice ?"
  end

  test "priorite_gestes : chauffe_eau a un gain EP > 0 sur bien gaz (n'est plus un no-op)" do
    r = PropertyDpeMatrixService.call(appartement_copro_gaz_collectif)
    ce = r[:priorite_gestes].find { |i| i[:code] == "chauffe_eau" }
    assert ce, "chauffe_eau doit apparaître dans priorite_gestes"
    # Sur gaz : gain EP modéré (~1,7 kWhEP/m²) mais strict > 0.
    assert_operator ce[:gain_ep], :>, 0.0,
      "chauffe_eau ne doit plus rendre 0 sur bien gaz — obtenu #{ce[:gain_ep]}"
    assert_operator ce[:gain_co2], :>, 0.0,
      "chauffe_eau doit aussi améliorer le CO2 sur gaz — obtenu #{ce[:gain_co2]}"
  end

  test "priorite_gestes : chauffe_eau reste neutre sur bien PAC (anti-double-compte)" do
    # Le chauffage étant déjà :pac, energie_ecs = :pac dans les deux modes
    # (:standard et :cet). Le CET est redondant → gain nul, comme pour le
    # geste chauffage sur ce bien.
    r = PropertyDpeMatrixService.call(maison_pac_non_isolee)
    ce = r[:priorite_gestes].find { |i| i[:code] == "chauffe_eau" }
    assert_in_delta 0.0, ce[:gain_ep], 0.5,
      "chauffe_eau sur bien déjà PAC doit rester neutre — obtenu #{ce[:gain_ep]}"
    assert_in_delta 0.0, ce[:gain_co2], 0.1,
      "chauffe_eau sur bien déjà PAC — CO2 doit rester neutre"
  end
end
