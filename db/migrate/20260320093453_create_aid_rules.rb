class CreateAidRules < ActiveRecord::Migration[7.2]
  def change
    create_table :aid_rules do |t|
      t.string   :name,            null: false
      t.string   :slug,            null: false, index: { unique: true }
      t.string   :aid_type        # mpr, cee, eco_ptz, local
      t.string   :territory       # national, grand_nancy
      t.text     :description

      # Conditions d'éligibilité (JSON)
      t.jsonb    :conditions,      default: {}

      # Calcul du montant
      t.string   :amount_type     # fixed, per_m2, percentage, formula
      t.decimal  :amount_value,   precision: 10, scale: 2
      t.decimal  :amount_max,     precision: 10, scale: 2
      t.decimal  :amount_min,     precision: 10, scale: 2
      t.string   :amount_base     # cost_ht, cost_ttc, surface_m2
      t.text     :amount_notes    # explications lisibles

      # Validité
      t.date     :valid_from,      null: false
      t.date     :valid_until
      t.boolean  :active,          default: true

      # Traçabilité
      t.string   :source_url
      t.string   :source_label
      t.integer  :priority,        default: 0  # ordre d'application

      t.timestamps
    end

    # Index pour la recherche par territoire et type
    add_index :aid_rules, [:territory, :aid_type, :active]
  end
end
