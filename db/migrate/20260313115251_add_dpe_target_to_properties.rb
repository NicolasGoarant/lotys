class AddDpeTargetToProperties < ActiveRecord::Migration[7.2]
  def change
    add_column :properties, :dpe_target, :string
  end
end
