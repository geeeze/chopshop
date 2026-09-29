ActiveRecord::Schema.define(version: 20260929000100) do
  create_table "jobs" do |t|
    t.string   "name", null: false
    t.string   "state", default: "pending", null: false
    t.string   "source_kind", default: "raster"          # raster | svg
    t.string   "input_path", null: false                  # path on the runner box
    t.string   "stem", null: false
    t.json     "spec", default: {}
    t.string   "runner", default: "mock", null: false
    t.string   "runner_job_id"
    t.string   "active_job_id"                            # Solid Queue entry, discardable pre-run
    t.json     "steps_state"                              # step list progress: which step ran, what it produced
    t.datetime "queued_at", default: -> { "CURRENT_TIMESTAMP" }
    t.datetime "started_at"
    t.datetime "finished_at"
    t.json     "prep_summary"
    t.integer  "candidate_count", default: 0
    t.json     "comparison"
    t.string   "error"
    t.string   "owner"                                # per-user isolation handle
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
    t.string   "owner"                                # per-user isolation handle
    t.datetime "queued_at", default: -> { "CURRENT_TIMESTAMP" }
    t.datetime "finished_at"
    t.datetime "created_at", default: -> { "CURRENT_TIMESTAMP" }
  end
  add_index "validations", ["job_id"]

  create_table "scrapbook_items" do |t|
    t.string   "name", null: false                # display name (candidate_06.svg, proof_04.png, …)
    t.string   "kind", null: false                # source | invert | candidate | proof | upload
    t.string   "file", null: false                # stored basename under storage/scrapbook/
    t.string   "sha256"                           # checksum at creation — the digest of the stored bytes
    t.string   "owner"                             # nullable: one operator today, pivot-ready
    t.integer  "job_id"                            # provenance only — survives the job's deletion
    t.datetime "created_at", default: -> { "CURRENT_TIMESTAMP" }
    t.datetime "updated_at", default: -> { "CURRENT_TIMESTAMP" }
  end
  add_index "scrapbook_items", ["owner"]
  add_index "scrapbook_items", ["job_id"]

  create_table "composites" do |t|
    t.string   "name", null: false
    t.integer  "width", null: false
    t.integer  "height", null: false
    t.string   "background", default: "transparent" # transparent | a #rrggbb
    # [{kind, src, name, x, y, w, h, z, opacity, hue, visible}] — `kind` is
    # "raster" (pixels) or "vector" (an SVG composed as vectors); a layer without
    # it is raster. Kept in step with AddPaletteToComposites and the model.
    t.json     "layers", default: []                 # [{kind, src, name, x, y, w, h, z, opacity, hue, visible}]
    t.json     "palette", default: []                # ["#rrggbb", …] a compose may draw with
    t.string   "owner"                              # nullable: one operator today, pivot-ready
    t.datetime "created_at", default: -> { "CURRENT_TIMESTAMP" }
    t.datetime "updated_at", default: -> { "CURRENT_TIMESTAMP" }
  end
  add_index "composites", ["owner"]

  # The candidate-triage LEARNING SIGNAL: one row per human action (star,
  # unstar, pick, delete) a future learned ranker trains on. NO foreign key to
  # jobs — `job_id` is provenance only, so an event outlives the job it
  # describes, exactly as a scrapbook item does. `pos` is the artifact's 1-based
  # rank on the ordered candidate list when the action was made on one;
  # `svg_sha` is the artifact's checksum; `ranker` names the ranker that
  # produced the order; `payload` holds the per-action detail.
  create_table "events" do |t|
    t.string   "owner"
    t.string   "event", null: false
    t.integer  "job_id"                            # provenance only — survives the job's deletion
    t.string   "svg_sha"
    t.integer  "pos"
    t.string   "ranker"
    t.json     "payload", default: {}
    t.datetime "created_at", default: -> { "CURRENT_TIMESTAMP" }
    t.datetime "updated_at", default: -> { "CURRENT_TIMESTAMP" }
  end
  add_index "events", ["owner"]
  add_index "events", ["job_id"]
  add_index "events", ["event"]

  # Per-user identity. Password-only: the password IS the identity (no username,
  # no directory). `handle` is the internal owner key every row carries; a
  # user's jobs/candidates/proofs/scrapbook/composites are all scoped to it.
  create_table "users" do |t|
    t.string   "handle", null: false
    t.string   "password_digest", null: false
    t.datetime "created_at", default: -> { "CURRENT_TIMESTAMP" }
    t.datetime "updated_at", default: -> { "CURRENT_TIMESTAMP" }
  end
  add_index "users", ["handle"], unique: true

  # ---------------------------------------------------------------------------
  # Solid Queue — the studio's job queue. One queue ("runs"), one worker thread
  # (config/queue.yml), so no two jobs are ever dispatched to their runners at
  # once. Lives in the primary database: one server, one SQLite file.
  # ---------------------------------------------------------------------------
  create_table "solid_queue_blocked_executions" do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.string "concurrency_key", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.index [ "concurrency_key", "priority", "job_id" ], name: "index_solid_queue_blocked_executions_for_release"
    t.index [ "expires_at", "concurrency_key" ], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index [ "job_id" ], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions" do |t|
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.datetime "created_at", null: false
    t.index [ "job_id" ], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index [ "process_id", "job_id" ], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions" do |t|
    t.bigint "job_id", null: false
    t.text "error"
    t.datetime "created_at", null: false
    t.index [ "job_id" ], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs" do |t|
    t.string "queue_name", null: false
    t.string "class_name", null: false
    t.text "arguments"
    t.integer "priority", default: 0, null: false
    t.string "active_job_id"
    t.datetime "scheduled_at"
    t.datetime "finished_at"
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "batch_id"
    t.index [ "active_job_id" ], name: "index_solid_queue_jobs_on_active_job_id"
    t.index [ "batch_id" ], name: "index_solid_queue_jobs_on_batch_id"
    t.index [ "class_name" ], name: "index_solid_queue_jobs_on_class_name"
    t.index [ "finished_at" ], name: "index_solid_queue_jobs_on_finished_at"
    t.index [ "queue_name", "finished_at" ], name: "index_solid_queue_jobs_for_filtering"
    t.index [ "scheduled_at", "finished_at" ], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses" do |t|
    t.string "queue_name", null: false
    t.datetime "created_at", null: false
    t.index [ "queue_name" ], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes" do |t|
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.bigint "supervisor_id"
    t.integer "pid", null: false
    t.string "hostname"
    t.text "metadata"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.index [ "last_heartbeat_at" ], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index [ "name", "supervisor_id" ], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index [ "supervisor_id" ], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions" do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "created_at", null: false
    t.index [ "job_id" ], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index [ "priority", "job_id" ], name: "index_solid_queue_poll_all"
    t.index [ "queue_name", "priority", "job_id" ], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions" do |t|
    t.bigint "job_id", null: false
    t.string "task_key", null: false
    t.datetime "run_at", null: false
    t.datetime "created_at", null: false
    t.index [ "job_id" ], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index [ "task_key", "run_at" ], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks" do |t|
    t.string "key", null: false
    t.string "schedule", null: false
    t.string "command", limit: 2048
    t.string "class_name"
    t.text "arguments"
    t.string "queue_name"
    t.integer "priority", default: 0
    t.boolean "static", default: true, null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index [ "key" ], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index [ "static" ], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions" do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "scheduled_at", null: false
    t.datetime "created_at", null: false
    t.index [ "job_id" ], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index [ "scheduled_at", "priority", "job_id" ], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores" do |t|
    t.string "key", null: false
    t.integer "value", default: 1, null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index [ "expires_at" ], name: "index_solid_queue_semaphores_on_expires_at"
    t.index [ "key", "value" ], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index [ "key" ], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "solid_queue_batches" do |t|
    t.string "active_job_batch_id"
    t.string "description"
    t.text "on_finish"
    t.text "on_success"
    t.text "on_failure"
    t.text "metadata"
    t.integer "total_jobs", default: 0, null: false
    t.integer "completed_jobs", default: 0, null: false
    t.integer "failed_jobs", default: 0, null: false
    t.datetime "enqueued_at"
    t.datetime "finished_at"
    t.datetime "failed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index [ "active_job_batch_id" ], name: "index_solid_queue_batches_on_active_job_batch_id", unique: true
    t.index [ "finished_at" ], name: "index_solid_queue_batches_on_finished_at"
  end

  create_table "solid_queue_batch_executions" do |t|
    t.bigint "job_id", null: false
    t.bigint "batch_id", null: false
    t.datetime "created_at", null: false
    t.index [ "job_id" ], name: "index_solid_queue_batch_executions_on_job_id", unique: true
    t.index [ "batch_id" ], name: "index_solid_queue_batch_executions_on_batch_id"
  end
end
