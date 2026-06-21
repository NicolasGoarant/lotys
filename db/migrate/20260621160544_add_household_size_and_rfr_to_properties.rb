class AddHouseholdSizeAndRfrToProperties < ActiveRecord::Migration[7.2]
  def change
    add_column :properties, :household_size, :integer
    add_column :properties, :rfr, :integer
  end
end
