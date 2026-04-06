class AddSurfacePostesToProperties < ActiveRecord::Migration[7.2]
  def change
    add_column :properties, :surface_ite, :decimal
    add_column :properties, :surface_iti, :decimal
    add_column :properties, :surface_sarking, :decimal
    add_column :properties, :surface_combles_perdus, :decimal
    add_column :properties, :surface_toiture_terrasse, :decimal
    add_column :properties, :surface_plancher_bas, :decimal
  end
end
