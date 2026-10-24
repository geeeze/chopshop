# The redesign's container tables: Project (owner of jobs), Source (into
# the project), Output (from a job, back to the project), and Tag (two-tier,
# polymorphic). The `is_test` column is real (not a `name LIKE 'smoke-%'` lie),
# and `sequence` lives on the project row rather than `MAX(sequence)+1`,
# avoiding the read-then-write race. All four tables are `Owned`, so reads
# are scoped to the signed-in operator.
class CreateProjectContainer < ActiveRecord::Migration[8.1]
  def change
    create_table :projects do |t|
      t.string   :name, null: false
      t.boolean  :is_test, default: false, null: false
      # The sequence counter, incremented under the row lock at dispatch time.
      t.integer  :next_sequence, default: 0, null: false
      # The owner scope — the operator who owns this workspace.
      t.string   :owner, null: false
      t.timestamps
    end
    add_index :projects, %i[name owner], unique: true, name: "index_projects_on_owner_name"

    create_table :sources do |t|
      t.references :project, foreign_key: true
      t.string   :name, null: false
      t.string   :source_type, default: "raster", null: false # raster | svg | generated | compound | composite
      t.timestamps
      # The owner stamps at creation through Owned.
      t.string   :owner, null: false
    end
    add_index :sources, %i[project_id name], unique: true

    create_table :outputs do |t|
      t.references :project, foreign_key: true
      t.references :job, foreign_key: true
      t.string   :file_name, null: false
      t.string   :output_kind, default: "candidate", null: false # candidate | proof | manifest | dataset | file | drawing | archive | image | frame
      # A SHA256 of the real bytes, so a flattened composite that once carried nil
      # can be found again. Without it the row is a row belonging to nothing.
      t.string   :sha256, limit: 64, null: false
      t.timestamps
      t.string   :owner, null: false
    end
    add_index :outputs, %i[job_id file_name]
    add_index :outputs, %i[sha256], name: "index_outputs_on_sha256"

    # Two-tier tags, one table. `kind: system` (derived, never typed) and
    # `kind: operator` (free text: `client-work`, `redo`). The polymorphic form
    # joins Project, Source, Job and Output without a second copy of the vocabulary.
    create_table :tags do |t|
      t.references :taggable, polymorphic: true, null: false
      t.string   :name, null: false
      t.string   :kind, default: "operator", null: false # system | operator
      t.timestamps
      t.string   :owner, null: false
    end
    add_index :tags, %i[taggable_type taggable_id name kind owner],
              unique: true, name: "index_tags_on_taggable_name_kind"

    # The job container: the redesign's link from the container to the work.
    # Every job gains `project_id`, `source_id`, `sequence`, `runner_stem`,
    # and the real `is_test` column that replaces `name LIKE 'smoke-%'`.
    add_column :jobs, :project_id, :integer
    add_column :jobs, :source_id, :integer
    # The runner's own stem, so the studio's derived one and the runner's can
    # be compared rather than silently disagreeing.
    add_column :jobs, :runner_stem, :string
    # The sequence number within the project, assigned on dispatch.
    add_column :jobs, :sequence, :integer
    # A real is_test column, not a name convention.
    add_column :jobs, :is_test, :boolean, default: false, null: false

    # The existing `stem` continues to live; `runner_stem` is ADDITIVE, not a
    # replacement, so existing rows keep resolving and nothing that already points
    # at `stem` breaks. The asymmetry (`stem` stays, `runner_stem` arrives) is
    # deliberate: the studio's stem is the public one; the runner's is the
    # provenance one, and comparing them is the feature.
    add_index :jobs, :project_id
    add_index :jobs, :source_id
    add_index :jobs, %i[project_id sequence], unique: true,
              name: "index_jobs_on_project_sequence"
    add_index :jobs, :is_test
  end
end