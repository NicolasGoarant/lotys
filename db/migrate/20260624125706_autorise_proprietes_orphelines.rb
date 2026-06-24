class AutoriseProprietesOrphelines < ActiveRecord::Migration[7.2]
  # Socle pour le parcours « estimation anonyme » :
  #   - user_id devient nullable → une Property peut exister sans propriétaire.
  #   - claim_token : jeton unique opaque qui sert au visiteur anonyme à
  #     retrouver son bien (cookie côté navigateur ↔ colonne en DB) puis à
  #     le revendiquer à l'inscription/connexion.
  #   - Index unique sur claim_token. En Postgres, un index unique tolère
  #     plusieurs valeurs NULL — les biens déjà possédés (claim_token nil)
  #     ne se télescopent donc pas entre eux.
  def change
    change_column_null :properties, :user_id, true
    add_column :properties, :claim_token, :string
    add_index  :properties, :claim_token, unique: true
  end
end
