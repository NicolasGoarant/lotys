class AddDetectedAddressToProperties < ActiveRecord::Migration[7.2]
  # Colonnes du parcours "adresse facultative" :
  #   - address_detected / city_detected / zipcode_detected : ce que le
  #     LLM a extrait des documents (jamais utilisé sans confirmation
  #     utilisateur — Property#address reste la source de vérité).
  #   - address_source : provenance de la détection ("dpe",
  #     "titre_propriete", "facture") ou "manuel" si l'utilisateur a
  #     saisi lui-même.
  #   - address_confirmed_at : timestamp de confirmation. Tant qu'il est
  #     NULL et qu'address est vide, on ne calcule pas les aides locales
  #     (dépendantes de zipcode / code_insee) et on n'affiche pas le bien
  #     comme "prêt à publier".
  #
  # Migration additive uniquement — aucun index (colonnes à faible
  # cardinalité de filtrage). Rollback trivial via down implicite.
  def change
    add_column :properties, :address_detected,     :string
    add_column :properties, :city_detected,        :string
    add_column :properties, :zipcode_detected,     :string
    add_column :properties, :address_source,       :string
    add_column :properties, :address_confirmed_at, :datetime
  end
end
