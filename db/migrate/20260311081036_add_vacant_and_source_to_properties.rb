class AddVacantAndSourceToProperties < ActiveRecord::Migration[7.2]
  def change
    add_column :properties, :vacant, :boolean
    add_column :properties, :source, :string
    add_column :properties, :vacancy_duration, :string
    add_column :properties, :vacancy_reason, :string
  end
end
