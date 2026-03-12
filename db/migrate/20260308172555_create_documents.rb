class CreateDocuments < ActiveRecord::Migration[7.2]
  def change
    create_table :documents do |t|
      t.references :property, null: false, foreign_key: true
      t.integer :document_type
      t.string :name
      t.text :ai_summary
      t.boolean :processed

      t.timestamps
    end
  end
end
