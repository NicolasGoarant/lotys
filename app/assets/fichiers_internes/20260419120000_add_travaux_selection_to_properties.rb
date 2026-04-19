class AddTravauxSelectionToProperties < ActiveRecord::Migration[7.2]
  def change
    # Stocke le choix utilisateur sur les travaux à réaliser.
    # Chaque clé correspond à un type canonique de travaux (voir TravauxMapperService).
    # Pré-rempli à true par PropertyAnalysisJob au moment du sync Claude, pour
    # que par défaut l'utilisateur voie le bouquet complet proposé par l'IA.
    # Peut ensuite être modifié via le formulaire de la card Rénovation énergétique.
    #
    # Structure attendue (voir Property.store_accessor) :
    #   {
    #     "isolation_toiture" => true,
    #     "isolation_murs" => true,
    #     "isolation_plancher_bas" => false,
    #     "chauffage" => true,
    #     "chauffe_eau" => true,
    #     "vmc" => true,
    #     "menuiseries" => false
    #   }
    add_column :properties, :travaux_selection, :jsonb, default: {}, null: false
  end
end
