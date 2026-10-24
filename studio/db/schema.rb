# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_10_12_000100) do
  create_table "candidates", force: :cascade do |t|
    t.integer "advisory", default: 0
    t.datetime "created_at", default: -> { "CURRENT_TIMESTAMP" }
    t.json "fidelity"
    t.string "file", null: false
    t.integer "filter_speckle"
    t.integer "hard", default: 0
    t.string "hierarchical"
    t.integer "job_id", null: false
    t.string "layer_a", default: "pending"
    t.string "layer_b", default: "pending"
    t.string "note"
    t.boolean "passed", default: false
    t.string "preset"
    t.json "sweep"
    t.boolean "use_palette"
    t.index ["job_id"], name: "index_candidates_on_job_id"
  end

  create_table "composites", force: :cascade do |t|
    t.string "background", default: "transparent"
    t.datetime "created_at", default: -> { "CURRENT_TIMESTAMP" }
    t.integer "height", null: false
    t.json "layers", default: []
    t.string "name", null: false
    t.string "owner"
    t.json "palette", default: []
    t.integer "project_id"
    t.datetime "updated_at", default: -> { "CURRENT_TIMESTAMP" }
    t.integer "width", null: false
    t.index ["owner"], name: "index_composites_on_owner"
    t.index ["project_id"], name: "index_composites_on_project_id"
  end

  create_table "dataset_views", force: :cascade do |t|
    t.datetime "built_at"
    t.datetime "created_at", null: false
    t.json "manifest", default: {}, null: false
    t.string "name", null: false
    t.json "rule", default: {}, null: false
    t.json "source_ids", default: [], null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_dataset_views_on_name", unique: true
  end

  create_table "events", force: :cascade do |t|
    t.datetime "created_at", default: -> { "CURRENT_TIMESTAMP" }
    t.string "event", null: false
    t.integer "job_id"
    t.string "owner"
    t.json "payload", default: {}
    t.integer "pos"
    t.string "ranker"
    t.string "svg_sha"
    t.datetime "updated_at", default: -> { "CURRENT_TIMESTAMP" }
    t.index ["event"], name: "index_events_on_event"
    t.index ["job_id"], name: "index_events_on_job_id"
    t.index ["owner"], name: "index_events_on_owner"
  end

  create_table "host_samples", force: :cascade do |t|
    t.datetime "captured_at", null: false
    t.bigint "cpu_idle"
    t.float "cpu_pct"
    t.bigint "cpu_total"
    t.datetime "created_at", default: -> { "CURRENT_TIMESTAMP" }
    t.float "load1"
    t.float "mem_pct"
    t.integer "mem_total_mb"
    t.integer "mem_used_mb"
    t.float "swap_pct"
    t.integer "swap_total_mb"
    t.integer "swap_used_mb"
    t.index ["captured_at"], name: "index_host_samples_on_captured_at"
  end

  create_table "jobs", force: :cascade do |t|
    t.string "active_job_id"
    t.integer "candidate_count", default: 0
    t.json "comparison"
    t.datetime "created_at", default: -> { "CURRENT_TIMESTAMP" }
    t.string "error"
    t.datetime "finished_at"
    t.string "input_path", null: false
    t.boolean "is_test", default: false, null: false
    t.string "name", null: false
    t.string "owner"
    t.json "prep_expand"
    t.json "prep_summary"
    t.integer "project_id"
    t.datetime "queued_at", default: -> { "CURRENT_TIMESTAMP" }
    t.string "runner", default: "mock", null: false
    t.string "runner_job_id"
    t.string "runner_stem"
    t.integer "sequence"
    t.integer "source_id"
    t.string "source_kind", default: "raster"
    t.json "spec", default: {}
    t.datetime "started_at"
    t.string "state", default: "pending", null: false
    t.string "stem", null: false
    t.json "steps_state"
    t.datetime "updated_at", default: -> { "CURRENT_TIMESTAMP" }
    t.index ["is_test"], name: "index_jobs_on_is_test"
    t.index ["project_id", "sequence"], name: "index_jobs_on_project_sequence", unique: true
    t.index ["project_id"], name: "index_jobs_on_project_id"
    t.index ["source_id"], name: "index_jobs_on_source_id"
  end

  create_table "outputs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "file_name", null: false
    t.integer "job_id"
    t.string "output_kind", default: "candidate", null: false
    t.string "owner", null: false
    t.integer "project_id"
    t.string "sha256", limit: 64, null: false
    t.datetime "updated_at", null: false
    t.index ["job_id", "file_name"], name: "index_outputs_on_job_id_and_file_name"
    t.index ["job_id"], name: "index_outputs_on_job_id"
    t.index ["project_id"], name: "index_outputs_on_project_id"
    t.index ["sha256"], name: "index_outputs_on_sha256"
  end

  create_table "projects", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "is_test", default: false, null: false
    t.string "name", null: false
    t.integer "next_sequence", default: 0, null: false
    t.string "owner", null: false
    t.datetime "updated_at", null: false
    t.index ["name", "owner"], name: "index_projects_on_owner_name", unique: true
  end

  create_table "prompt_records", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "fingerprint", null: false
    t.integer "job_id"
    t.datetime "last_used_at"
    t.text "prompt", null: false
    t.string "source"
    t.datetime "updated_at", null: false
    t.integer "uses_count", default: 1, null: false
    t.index ["fingerprint"], name: "index_prompt_records_on_fingerprint", unique: true
    t.index ["last_used_at"], name: "index_prompt_records_on_last_used_at"
  end

  create_table "prompt_sources", force: :cascade do |t|
    t.string "attribution"
    t.datetime "created_at", default: -> { "CURRENT_TIMESTAMP" }
    t.string "dataset", null: false
    t.float "guidance"
    t.integer "height"
    t.string "image_name"
    t.string "licence"
    t.json "meta", default: {}
    t.boolean "nsfw"
    t.string "part"
    t.string "phrase_root"
    t.text "prompt", null: false
    t.string "prompt_sha"
    t.string "sampler"
    t.integer "seed"
    t.integer "steps"
    t.string "topic"
    t.datetime "updated_at", default: -> { "CURRENT_TIMESTAMP" }
    t.integer "width"
    t.float "x"
    t.float "y"
    t.index ["dataset"], name: "index_prompt_sources_on_dataset"
    t.index ["part"], name: "index_prompt_sources_on_part"
    t.index ["phrase_root"], name: "index_prompt_sources_on_phrase_root"
    t.index ["prompt_sha"], name: "index_prompt_sources_on_prompt_sha"
    t.index ["topic"], name: "index_prompt_sources_on_topic"
  end

  create_table "scrapbook_items", force: :cascade do |t|
    t.datetime "created_at", default: -> { "CURRENT_TIMESTAMP" }
    t.string "file", null: false
    t.integer "job_id"
    t.string "kind", null: false
    t.string "name", null: false
    t.string "owner"
    t.string "sha256"
    t.datetime "updated_at", default: -> { "CURRENT_TIMESTAMP" }
    t.index ["job_id"], name: "index_scrapbook_items_on_job_id"
    t.index ["owner"], name: "index_scrapbook_items_on_owner"
  end

  create_table "session_drafts", force: :cascade do |t|
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.string "kind", null: false
    t.string "owner", null: false
    t.string "source"
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["owner", "kind"], name: "index_session_drafts_on_owner_and_kind"
    t.index ["token"], name: "index_session_drafts_on_token", unique: true
  end

  create_table "solid_queue_batch_executions", force: :cascade do |t|
    t.bigint "batch_id", null: false
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.index ["batch_id"], name: "index_solid_queue_batch_executions_on_batch_id"
    t.index ["job_id"], name: "index_solid_queue_batch_executions_on_job_id", unique: true
  end

  create_table "solid_queue_batches", force: :cascade do |t|
    t.string "active_job_batch_id"
    t.integer "completed_jobs", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "description"
    t.datetime "enqueued_at"
    t.datetime "failed_at"
    t.integer "failed_jobs", default: 0, null: false
    t.datetime "finished_at"
    t.text "metadata"
    t.text "on_failure"
    t.text "on_finish"
    t.text "on_success"
    t.integer "total_jobs", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["active_job_batch_id"], name: "index_solid_queue_batches_on_active_job_batch_id", unique: true
    t.index ["finished_at"], name: "index_solid_queue_batches_on_finished_at"
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.string "concurrency_key", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error"
    t.bigint "job_id", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "active_job_id"
    t.text "arguments"
    t.bigint "batch_id"
    t.string "class_name", null: false
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at"
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["batch_id"], name: "index_solid_queue_jobs_on_batch_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "queue_name", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "hostname"
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.text "metadata"
    t.string "name", null: false
    t.integer "pid", null: false
    t.bigint "supervisor_id"
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.datetime "run_at", null: false
    t.string "task_key", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.text "arguments"
    t.string "class_name"
    t.string "command", limit: 2048
    t.datetime "created_at", null: false
    t.text "description"
    t.string "key", null: false
    t.integer "priority", default: 0
    t.string "queue_name"
    t.string "schedule", null: false
    t.boolean "static", default: true, null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.integer "value", default: 1, null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "sources", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.string "owner", null: false
    t.integer "project_id"
    t.string "source_type", default: "raster", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "name"], name: "index_sources_on_project_id_and_name", unique: true
    t.index ["project_id"], name: "index_sources_on_project_id"
  end

  create_table "tags", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "kind", default: "operator", null: false
    t.string "name", null: false
    t.string "owner", null: false
    t.integer "taggable_id", null: false
    t.string "taggable_type", null: false
    t.datetime "updated_at", null: false
    t.index ["taggable_type", "taggable_id", "name", "kind", "owner"], name: "index_tags_on_taggable_name_kind", unique: true
    t.index ["taggable_type", "taggable_id"], name: "index_tags_on_taggable"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", default: -> { "CURRENT_TIMESTAMP" }
    t.string "handle", null: false
    t.string "password_digest", null: false
    t.datetime "updated_at", default: -> { "CURRENT_TIMESTAMP" }
    t.index ["handle"], name: "index_users_on_handle", unique: true
  end

  create_table "validations", force: :cascade do |t|
    t.integer "candidate_id"
    t.datetime "created_at", default: -> { "CURRENT_TIMESTAMP" }
    t.string "error"
    t.string "file", null: false
    t.datetime "finished_at"
    t.json "jev_answers"
    t.json "jev_meta"
    t.integer "job_id", null: false
    t.json "manifest"
    t.string "owner"
    t.datetime "queued_at", default: -> { "CURRENT_TIMESTAMP" }
    t.string "runner_validation_id"
    t.string "state", default: "pending", null: false
    t.index ["job_id"], name: "index_validations_on_job_id"
  end

  add_foreign_key "composites", "projects"
  add_foreign_key "outputs", "jobs"
  add_foreign_key "outputs", "projects"
  add_foreign_key "sources", "projects"
end
