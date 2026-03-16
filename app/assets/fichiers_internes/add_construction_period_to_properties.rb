class AddConstructionPeriodToProperties < ActiveRecord::Migration[7.2]
  def change
    add_column :properties, :construction_period, :string
  end
end
