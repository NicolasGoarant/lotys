class CreateLocalAidSchemes < ActiveRecord::Migration[7.2]
  def change
    create_table :local_aid_schemes do |t|
      t.string  :name,           null: false
      t.string  :territory,      null: false
      t.string  :aid_type,       null: false
      t.jsonb   :zipcodes,       default: []
      t.jsonb   :property_types, default: nil
      t.decimal :rate_tres_modeste,   precision: 5, scale: 2
      t.decimal :rate_modeste,        precision: 5, scale: 2
      t.decimal :rate_intermediaire,  precision: 5, scale: 2
      t.decimal :rate_superieur,      precision: 5, scale: 2
      t.integer :max_tres_modeste
      t.integer :max_modeste
      t.integer :max_intermediaire
      t.integer :max_superieur
      t.jsonb   :forfait_data,   default: nil
      t.text    :conditions_text
      t.text    :warning_text
      t.string  :contact_name
      t.string  :contact_url
      t.string  :source_url
      t.string  :source_label
      t.date    :valid_from
      t.date    :valid_until
      t.boolean :active, default: true, null: false
      t.timestamps
    end
    add_index :local_aid_schemes, :territory
    add_index :local_aid_schemes, :active
    add_index :local_aid_schemes, :zipcodes, using: :gin
  end
end
