class CreateDeviceSimulations < ActiveRecord::Migration[7.2]
  def change
    create_table :device_simulations do |t|
      t.references :property, null: false, foreign_key: true
      t.boolean :eligible_eco_ptz
      t.integer :eco_ptz_max_amount
      t.boolean :eligible_maprimrenov
      t.integer :maprimrenov_amount
      t.boolean :eligible_cee
      t.integer :cee_estimated_amount
      t.integer :total_aid_estimate
      t.text :notes
      t.jsonb :simulation_data

      t.timestamps
    end
  end
end
