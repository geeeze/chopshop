class AddProjectIdToComposites < ActiveRecord::Migration[8.1]
  def change
    add_column :composites, :project_id, :integer
    add_index :composites, :project_id
    add_foreign_key :composites, :projects
  end
end
