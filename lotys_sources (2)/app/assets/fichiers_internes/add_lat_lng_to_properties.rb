class AddLatLngToProperties < ActiveRecord::Migration[7.2]
  def change
    add_column :properties, :lat, :float
    add_column :properties, :lng, :float
  end
end
