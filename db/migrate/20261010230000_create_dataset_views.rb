class CreateDatasetViews < ActiveRecord::Migration[7.1]
  def change
    create_table :dataset_views do |t|
      # The view's name — the operator-facing handle ("reference portraits").
      # Unique: a name IS the view, so two views cannot share one.
      t.string :name, null: false
      # The rule set, stored as DATA not code (issue #48): the filters that
      # define the subset, plus optional explicit include/exclude ids and a
      # size cap. Kept as a JSON column so a rule is inspectable and editable
      # without a migration — the whole point of "rule as data".
      t.json :rule, null: false, default: {}
      # The manifest: what the last build produced — the count, the rule that
      # made it (echoed for provenance), and the omitted-with-reason list
      # (dmpool honesty: a view never hides a record, it lists omissions).
      t.json :manifest, null: false, default: {}
      # The built row set: the prompt_source ids the view resolved to, in
      # deterministic (sorted) order. Stored so a draw reads a stable slice
      # without re-running the filter every time, and so a rebuild can be
      # compared against the prior set.
      t.json :source_ids, null: false, default: []
      t.datetime :built_at
      t.timestamps
    end
    add_index :dataset_views, :name, unique: true
  end
end
