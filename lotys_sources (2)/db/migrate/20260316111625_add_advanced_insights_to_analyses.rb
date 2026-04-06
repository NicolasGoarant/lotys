class AddAdvancedInsightsToAnalyses < ActiveRecord::Migration[7.2]
  def change
    add_column :analyses, :score_energie, :integer
    add_column :analyses, :score_patrimonial, :integer
    add_column :analyses, :travaux_timeline, :jsonb
    add_column :analyses, :estimated_value_after_works, :integer
    add_column :analyses, :estimated_gain_after_works, :integer
  end
end
