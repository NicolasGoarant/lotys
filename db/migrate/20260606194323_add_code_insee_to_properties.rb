class AddCodeInseeToProperties < ActiveRecord::Migration[7.2]
  def change
    add_column :properties, :code_insee, :string
  end
end
