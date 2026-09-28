ActiveRecord::Schema.define(version: 1) do
  create_table "jobs" do |t|
    t.string   "name", null: false
    t.string   "state", default: "pending", null: false
    t.string   "source_kind", default: "raster"          # raster | svg
    t.string   "input_path", null: false                  # path on the runner box
    t.string   "stem", null: false
    t.json     "spec", default: {}
    t.string   "runner", default: "mock", null: false
    t.string   "runner_job_id"
    t.datetime "queued_at", default: -> { "CURRENT_TIMESTAMP" }
    t.datetime "started_at"
    t.datetime "finished_at"
    t.json     "prep_summary"
    t.integer  "candidate_count", default: 0
    t.json     "comparison"
    t.string   "error"
    t.datetime "created_at", default: -> { "CURRENT_TIMESTAMP" }
    t.datetime "updated_at", default: -> { "CURRENT_TIMESTAMP" }
  end

  create_table "candidates" do |t|
    t.integer  "job_id", null: false
    t.string   "file", null: false                        # e.g. candidate_04.svg
    t.string   "preset"
    t.string   "hierarchical"
    t.integer  "filter_speckle"
    t.boolean  "use_palette"
    t.json     "sweep"
    t.string   "layer_a", default: "pending"              # pass|fail|error|pending
    t.string   "layer_b", default: "pending"
    t.integer  "hard", default: 0
    t.integer  "advisory", default: 0
    t.json     "fidelity"
    t.boolean  "passed", default: false
    t.string   "note"
    t.datetime "created_at", default: -> { "CURRENT_TIMESTAMP" }
  end
  add_index "candidates", ["job_id"]

  create_table "validations" do |t|
    t.integer  "job_id", null: false
    t.integer  "candidate_id"
    t.string   "file", null: false                        # candidate file picked
    t.string   "state", default: "pending", null: false   # pending|running|done|error
    t.string   "runner_validation_id"
    t.json     "manifest"
    t.json     "jev_answers"
    t.json     "jev_meta"
    t.string   "error"
    t.datetime "queued_at", default: -> { "CURRENT_TIMESTAMP" }
    t.datetime "finished_at"
    t.datetime "created_at", default: -> { "CURRENT_TIMESTAMP" }
  end
  add_index "validations", ["job_id"]

  create_table "scrapbook_items" do |t|
    t.string   "name", null: false                # display name (candidate_06.svg, proof_04.png, …)
    t.string   "kind", null: false                # source | invert | candidate | proof | upload
    t.string   "file", null: false                # stored basename under storage/scrapbook/
    t.string   "owner"                             # nullable: one operator today, pivot-ready
    t.integer  "job_id"                            # provenance only — survives the job's deletion
    t.datetime "created_at", default: -> { "CURRENT_TIMESTAMP" }
    t.datetime "updated_at", default: -> { "CURRENT_TIMESTAMP" }
  end
  add_index "scrapbook_items", ["owner"]
  add_index "scrapbook_items", ["job_id"]
end
