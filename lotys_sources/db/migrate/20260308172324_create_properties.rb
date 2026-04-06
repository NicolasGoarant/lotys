class CreateProperties < ActiveRecord::Migration[7.2]
  def change
    create_table :properties do |t|
      t.references :user, null: false, foreign_key: true
      t.string :address
      t.string :city
      t.string :zipcode
      t.integer :surface
      t.string :property_type
      t.integer :construction_year
      t.string :dpe_class
      t.integer :nb_rooms
      t.integer :nb_lots
      t.boolean :is_copropriete
      t.text :description
      t.integer :status

      t.timestamps
    end
  end
end
