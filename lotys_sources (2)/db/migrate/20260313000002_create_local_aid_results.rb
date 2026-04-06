class CreateLocalAidResults < ActiveRecord::Migration[7.2]
  def change
    create_table :local_aid_results do |t|
      t.references :property,         null: false, foreign_key: true
      t.references :local_aid_scheme, null: false, foreign_key: true
      t.boolean :eligible,            null: false, default: false
      t.string  :ineligibility_reason
      t.jsonb   :amounts, default: {}
      t.datetime :computed_at
      t.timestamps
    end
    add_index :local_aid_results, [:property_id, :local_aid_scheme_id], unique: true
    add_index :local_aid_results, :eligible
  end
end
