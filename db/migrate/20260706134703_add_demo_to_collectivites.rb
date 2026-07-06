# Ajoute un flag `demo` sur les collectivités portail.
#
# Une collectivité `demo: true` est un portail présenté à titre de
# démonstration (prototype montré à la Métropole + partenaire pressenti,
# pas de service officiel signé). La vue portail affiche alors un bandeau
# de mise en garde en tête, et le badge de provenance sur les fiches de
# biens précise "(démonstration)" dans son title.
#
# Le jour de la signature d'un vrai partenariat, il suffit de basculer
# la valeur à false en console — aucun redéploiement, tout disparaît.
#
#   c = Collectivite.find_by(slug: "grand-nancy")
#   c.update!(demo: false)
#
# Default `false` pour que toute future collectivité soit considérée
# comme officielle par défaut — l'affichage démo est un opt-in explicite.
# La backfill inline pose demo: true UNIQUEMENT sur grand-nancy pour
# refléter l'état réel du jour du déploiement (démo en cours).
class AddDemoToCollectivites < ActiveRecord::Migration[7.2]
  def up
    add_column :collectivites, :demo, :boolean, default: false, null: false

    # Backfill one-off : Grand Nancy est en démo au moment du déploiement.
    # On tape la table directement (execute) plutôt que Collectivite.find_by
    # pour ne pas dépendre du modèle Ruby à ce moment du cycle de migration.
    execute <<~SQL
      UPDATE collectivites SET demo = TRUE WHERE slug = 'grand-nancy';
    SQL
  end

  def down
    remove_column :collectivites, :demo
  end
end
