class CreateComposites < ActiveRecord::Migration[8.1]
  def change
    create_table :composites do |t|
      t.string   :name, null: false
      t.integer  :job_id
      t.json     :palette, default: []
      t.json     :data, default: {}    # manifest/findings content
      t.string   :state, default: "pending"
      t.datetime :created_at, null: false
      t.datetime :updated_at, null: false
    end
    add_index :composites, :job_id
  end
end
