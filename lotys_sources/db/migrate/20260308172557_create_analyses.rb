class CreateAnalyses < ActiveRecord::Migration[7.2]
  def change
    create_table :analyses do |t|
      t.references :property, null: false, foreign_key: true
      t.string :analysis_type
      t.text :content
      t.text :recommendations
      t.jsonb :raw_response
      t.integer :status

      t.timestamps
    end
  end
end
