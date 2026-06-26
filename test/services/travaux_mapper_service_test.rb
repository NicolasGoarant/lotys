require "test_helper"

class TravauxMapperServiceTest < ActiveSupport::TestCase

  # ─── Constantes ─────────────────────────────────────────────────────

  test "CANONICAL_CODES contient exactement 7 macro-postes" do
    assert_equal 7, TravauxMapperService::CANONICAL_CODES.size
  end

  test "CANONICAL_CODES, LABELS et EMOJIS partagent les mêmes clés" do
    codes = TravauxMapperService::CANONICAL_CODES.sort
    assert_equal codes, TravauxMapperService::LABELS.keys.sort
    assert_equal codes, TravauxMapperService::EMOJIS.keys.sort
  end

  test "MACRO_TO_EQUIPEMENTS et MACRO_TO_SURFACES couvrent les 7 codes canoniques" do
    codes = TravauxMapperService::CANONICAL_CODES.sort
    assert_equal codes, TravauxMapperService::MACRO_TO_EQUIPEMENTS.keys.sort
    assert_equal codes, TravauxMapperService::MACRO_TO_SURFACES.keys.sort
  end

  # ─── code_for_poste ────────────────────────────────────────────────

  test "code_for_poste mappe les libellés chauffage" do
    assert_equal "chauffage", TravauxMapperService.code_for_poste("Installation PAC air/eau")
    assert_equal "chauffage", TravauxMapperService.code_for_poste("Remplacement chaudière fioul")
    assert_equal "chauffage", TravauxMapperService.code_for_poste("Pose d'un poêle à granulés")
    assert_equal "chauffage", TravauxMapperService.code_for_poste("Pompe à chaleur géothermique")
  end

  test "code_for_poste mappe les libellés d'isolation" do
    assert_equal "isolation_toiture", TravauxMapperService.code_for_poste("Isolation des combles perdus")
    assert_equal "isolation_toiture", TravauxMapperService.code_for_poste("Sarking de la toiture")
    assert_equal "isolation_toiture", TravauxMapperService.code_for_poste("Isolation des rampants")
    assert_equal "isolation_murs",    TravauxMapperService.code_for_poste("ITE façade nord")
    assert_equal "isolation_murs",    TravauxMapperService.code_for_poste("Isolation par l'intérieur")
    assert_equal "isolation_plancher_bas", TravauxMapperService.code_for_poste("Isolation plancher bas")
    assert_equal "isolation_plancher_bas", TravauxMapperService.code_for_poste("Vide sanitaire")
  end

  test "code_for_poste mappe chauffe_eau, vmc, menuiseries" do
    assert_equal "chauffe_eau", TravauxMapperService.code_for_poste("Chauffe-eau thermodynamique")
    assert_equal "chauffe_eau", TravauxMapperService.code_for_poste("Ballon thermodynamique")
    assert_equal "vmc",         TravauxMapperService.code_for_poste("VMC double flux")
    assert_equal "vmc",         TravauxMapperService.code_for_poste("Ventilation contrôlée")
    assert_equal "menuiseries", TravauxMapperService.code_for_poste("Remplacement des fenêtres")
    assert_equal "menuiseries", TravauxMapperService.code_for_poste("Double vitrage")
  end

  test "code_for_poste renvoie nil pour les libellés non mappés ou vides" do
    assert_nil TravauxMapperService.code_for_poste("Peinture des volets")
    assert_nil TravauxMapperService.code_for_poste("")
    assert_nil TravauxMapperService.code_for_poste(nil)
    assert_nil TravauxMapperService.code_for_poste("   ")
  end

  # ─── equipements_for / surfaces_for ───────────────────────────────

  test "equipements_for avec nil renvoie :all (pas de filtre)" do
    assert_equal :all, TravauxMapperService.equipements_for(nil)
  end

  test "equipements_for avec [] ne renvoie que les ALWAYS_ON_EQUIPEMENTS" do
    result = TravauxMapperService.equipements_for([])
    assert_equal TravauxMapperService::ALWAYS_ON_EQUIPEMENTS.sort, result.sort
  end

  test "equipements_for développe la macro chauffage en ses équipements" do
    result = TravauxMapperService.equipements_for(["chauffage"])
    assert_includes result, "pac_air_eau"
    assert_includes result, "pac_geothermique"
    assert_includes result, "poele_granules"
    assert_includes result, "depose_fioul"
    # audit_energetique reste always-on
    assert_includes result, "audit_energetique"
    # Pas d'équipement chauffe_eau dans ce macro
    refute_includes result, "chauffe_eau_thermo"
  end

  test "equipements_for de ['menuiseries'] ne contient que nb_parois_vitrees + always_on" do
    result = TravauxMapperService.equipements_for(["menuiseries"])
    assert_includes result, "nb_parois_vitrees"
    assert_includes result, "audit_energetique"
    refute_includes result, "pac_air_eau"
  end

  test "surfaces_for avec nil renvoie :all" do
    assert_equal :all, TravauxMapperService.surfaces_for(nil)
  end

  test "surfaces_for développe isolation_toiture en 3 surfaces" do
    result = TravauxMapperService.surfaces_for(["isolation_toiture"])
    assert_includes result, "sarking"
    assert_includes result, "combles_perdus"
    assert_includes result, "toiture_terrasse"
    refute_includes result, "ite"
  end

  test "surfaces_for combine plusieurs macros sans doublon" do
    result = TravauxMapperService.surfaces_for(["isolation_toiture", "isolation_murs"])
    assert_includes result, "sarking"  # via toiture
    assert_includes result, "ite"      # via murs
    assert_equal result.uniq, result, "surfaces_for doit dédoublonner"
  end

  # ─── POSTE_TO_MACRO : cohérence inverse ───────────────────────────

  test "POSTE_TO_MACRO : tous les macros cibles existent dans CANONICAL_CODES" do
    TravauxMapperService::POSTE_TO_MACRO.each do |poste, macro|
      assert_includes TravauxMapperService::CANONICAL_CODES, macro,
                      "Poste '#{poste}' mappe vers '#{macro}' qui n'est pas un code canonique"
    end
  end

  # ─── Robustesse ───────────────────────────────────────────────────

  test "equipements_for accepte des symbols au lieu de strings" do
    result = TravauxMapperService.equipements_for([:chauffage])
    assert_includes result, "pac_air_eau"
  end
end
