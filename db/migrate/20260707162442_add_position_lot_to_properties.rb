class AddPositionLotToProperties < ActiveRecord::Migration[7.2]
  # Position du lot dans son immeuble — pertinent UNIQUEMENT pour un
  # appartement. Détermine quelles parois donnent physiquement sur
  # l'extérieur vs sur un autre lot chauffé :
  #
  #   dernier_etage       : toiture réelle, plancher adjacent chauffé.
  #   etage_intermediaire : plancher ET toiture adjacents chauffés.
  #   rdc                 : plancher réel (sur cave/vide sanitaire) ;
  #                         toiture adjacente chauffée.
  #   inconnu             : pas encore extrait ni confirmé.
  #
  # Consommé par ProposableGestesService (commit 1) pour exclure des
  # cases à cocher les gestes inutiles (isolation toiture/plancher sur
  # les parois adjacentes à un autre lot) et par DpeEngineService
  # (commit 3) pour annuler les coefficients b de mitoyenneté verticale.
  #
  # ── Pattern identique à address_detected/confirmed ──
  # - position_lot              : valeur de vérité (colonne exploitée).
  # - position_lot_detected     : ce que le LLM a extrait des documents
  #                                (jamais utilisé sans confirmation).
  # - position_lot_confirmed_at : timestamp du clic explicite de
  #                                l'utilisateur. Tant qu'il est NULL,
  #                                la vue affiche le bandeau de
  #                                confirmation pour les appartements.
  #
  # Colonnes NULLABLES : les biens existants gardent NULL (aucune
  # migration de données ; comportement conservateur en aval). La
  # confirmation est demandée à l'utilisateur au prochain rendu de la
  # fiche pour les appartements — pas de migration silencieuse.
  def change
    add_column :properties, :position_lot,              :string
    add_column :properties, :position_lot_detected,     :string
    add_column :properties, :position_lot_confirmed_at, :datetime
  end
end
