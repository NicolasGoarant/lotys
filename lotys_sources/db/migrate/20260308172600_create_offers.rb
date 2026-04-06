class CreateOffers < ActiveRecord::Migration[7.2]
  def change
    create_table :offers do |t|
      t.references :property, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.integer :offer_type
      t.integer :amount
      t.text :description
      t.integer :status
      t.datetime :expires_at

      t.timestamps
    end
  end
end
