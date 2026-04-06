class CreateValuations < ActiveRecord::Migration[7.2]
  def change
    create_table :valuations do |t|
      t.references :property, null: false, foreign_key: true
      t.integer :estimated_value
      t.integer :min_value
      t.integer :max_value
      t.integer :bulk_sale_estimate
      t.jsonb :comparable_sales
      t.text :methodology
      t.jsonb :dvf_raw

      t.timestamps
    end
  end
end
