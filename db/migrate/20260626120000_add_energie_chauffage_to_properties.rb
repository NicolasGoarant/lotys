class AddEnergieChauffageToProperties < ActiveRecord::Migration[7.2]
  # Ajoute le champ structuré energie_chauffage (typé enum côté Ruby) +
  # sa source de capture energie_chauffage_source.
  #
  # Diagnostic Temps 2.6 : 9/13 biens à énergie ambiguë faute de signal
  # structuré ; l'écart entre hypothèses énergétiques vaut 1 classe DPE.
  # Le moteur DpeEngineService a besoin d'une énergie typée parmi
  # {gaz, fioul, electricite, bois, pac} ; on ajoute :inconnue pour
  # gérer l'absence honnête de donnée (pas d'invention).
  #
  # Sources de confiance (énumérées dans Property, voir
  # ENERGIE_SOURCE_HIERARCHIE) — du moins au plus fiable :
  #   inconnue < deduit < extrait_description < extrait_dpe < confirme_utilisateur
  #
  # Défaut :inconnue + null: false : aucun bien legacy ne reste avec NULL,
  # et la sémantique reste honnête (« on ne sait pas »).
  def change
    add_column :properties, :energie_chauffage,        :string, default: "inconnue", null: false
    add_column :properties, :energie_chauffage_source, :string, default: "inconnue", null: false
  end
end
