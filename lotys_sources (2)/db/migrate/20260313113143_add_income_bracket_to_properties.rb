class AddIncomeBracketToProperties < ActiveRecord::Migration[7.2]
  def change
    add_column :properties, :income_bracket, :string
  end
end
