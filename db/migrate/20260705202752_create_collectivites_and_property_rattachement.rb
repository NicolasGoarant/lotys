class CreateCollectivitesAndPropertyRattachement < ActiveRecord::Migration[7.2]
  # Feature "portail collectivité" (niveau 1 B2G) — deux changements
  # logiquement atomiques regroupés :
  #
  #   1. Table `collectivites` : entité représentant un EPCI (Métropole,
  #      Communauté d'Agglomération, …). Chaque collectivité porte son
  #      identité de portail (nom, slug URL, couleur primaire, mot
  #      d'accueil), la liste des codes INSEE des communes qu'elle
  #      couvre (source de vérité pour "bien dans le ressort") et un
  #      flag `active` pour ouvrir/fermer les portails sans détruire
  #      la donnée. Le logo est géré via Active Storage sur le modèle
  #      (cf. C2), pas de colonne dédiée ici.
  #
  #   2. `properties.collectivite_id` : rattachement d'un bien à une
  #      collectivité au moment où il est créé DEPUIS un portail EPCI.
  #      Nullable — la voie publique standard reste ouverte, aucune
  #      régression du parcours sans portail. FK avec `on_delete: :nullify`
  #      pour survivre à la suppression d'une collectivité (rare, mais
  #      on ne veut pas perdre les biens).
  #
  # Additif, rollback trivial via down implicite.
  def change
    create_table :collectivites do |t|
      t.string  :name,          null: false
      t.string  :slug,          null: false
      t.string  :primary_color, null: false  # hex #RRGGBB, contrainte format côté modèle
      t.text    :welcome_text                # mot d'accueil éditable, nullable pour ne pas bloquer
      t.jsonb   :insee_codes, default: [], null: false  # array de codes INSEE 5 chiffres
      t.boolean :active,        null: false, default: true

      t.timestamps
    end

    add_index :collectivites, :slug,   unique: true
    add_index :collectivites, :active
    add_index :collectivites, :insee_codes, using: :gin  # requêtes "collectivités couvrant ce code"

    add_reference :properties, :collectivite,
                  foreign_key: { on_delete: :nullify },
                  null: true,
                  index: true
  end
end
