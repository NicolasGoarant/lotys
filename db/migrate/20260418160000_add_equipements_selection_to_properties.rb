class AddEquipementsSelectionToProperties < ActiveRecord::Migration[7.2]
  def change
    # Stocke les équipements de chauffage / ECS / autres qui n'ont pas de surface
    # mais un booléen (PAC, VMC, insert, audit, etc.) ou un compteur
    # (nb_parois_vitrees pour les remplacements simple → double vitrage).
    #
    # Les 6 surfaces d'isolation (surface_ite, surface_iti, surface_sarking,
    # surface_combles_perdus, surface_toiture_terrasse, surface_plancher_bas)
    # restent dans leurs colonnes numeric dédiées.
    #
    # Structure attendue du jsonb (voir Property.store_accessor) :
    #   {
    #     "pac_air_eau" => true,
    #     "pac_geothermique" => false,
    #     "chauffe_eau_thermo" => false,
    #     "chauffe_eau_solaire" => false,
    #     "systeme_solaire_combine" => false,
    #     "pvt_eau" => false,
    #     "poele_buches" => false,
    #     "poele_granules" => true,
    #     "insert_foyer" => false,
    #     "raccordement_reseau_chaleur" => false,
    #     "depose_fioul" => false,
    #     "vmc_double_flux" => true,
    #     "audit_energetique" => false,
    #     "nb_parois_vitrees" => 0
    #   }
    add_column :properties, :equipements_selection, :jsonb, default: {}, null: false
  end
end
