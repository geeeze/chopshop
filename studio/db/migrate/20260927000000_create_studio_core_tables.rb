# The studio's original tables, which `schema.rb` was the only source for.
#
# WHY THIS MIGRATION EXISTS LATE, AND WHY IT IS NOT A NO-OP
#
# `jobs`, `candidates` and `validations` were created by `db/schema.rb` and never
# by a migration, because that is how this app was scaffolded. The consequence
# was a database that could only be built one way:
#
#     bin/rails db:migrate   # ABORTS on a fresh database
#
# with `20260928000500_add_palette_to_composites: Could not find table
# 'composites'`. A database built by replaying migrations in order never has
# these tables, so the first migration that mentions one of them fails. The
# workarounds were `db:test:prepare` (which loads schema.rb) for test and
# `RAILS_ENV=production db:migrate` for production, where the tables already
# existed -- so the only supported path was also the only one nobody tested.
#
# This migration, with `CreateComposites` and `CreateScrapbookItems`, closes
# that. `db:migrate` on an empty database now builds a complete one, and
# `test/lib/schema_drift_test.rb` holds the class of drift shut from then on: it
# asserts every table `schema.rb` describes is one some migration can create, so
# the next table added in one file and not the other fails the suite rather than
# waiting to be found in a broken development database.
#
# TWO THINGS ARE LOAD-BEARING HERE, and both are about ORDER rather than content.
#
# 1. GUARDED, because this migration is dated BEFORE the ones that alter these
#    tables, so it runs first on a fresh database and is a no-op on every
#    existing one. Unguarded, `create_table` would raise on every deployment that
#    already has the table and take the whole migrate down with it.
#
# 2. THE COLUMNS LATER MIGRATIONS ADD ARE DELIBERATELY ABSENT. `jobs.owner` and
#    `jobs.active_job_id` and `jobs.steps_state` are added by
#    `AddUsersAndOwnerIsolation`, `AddActiveJobIdToJobs` and
#    `AddStepsStateToJobs`; `validations.owner` by the first of those. Including
#    them here would make those migrations' `add_column` a duplicate on a fresh
#    database -- and `AddActiveJobIdToJobs` is NOT guarded, so it would abort.
#    The create migration therefore reconstructs the table as it was when
#    schema.rb first described it, and the later migrations build it forward from
#    there. That is what makes the replay produce the same schema the dump does.
class CreateStudioCoreTables < ActiveRecord::Migration[8.1]
  def change
    unless table_exists?(:jobs)
      create_table :jobs do |t|
        t.string   :name, null: false
        t.string   :state, default: "pending", null: false
        t.string   :source_kind, default: "raster"          # raster | svg
        t.string   :input_path, null: false                  # path on the runner box
        t.string   :stem, null: false
        t.json     :spec, default: {}
        t.string   :runner, default: "mock", null: false
        t.string   :runner_job_id
        t.datetime :queued_at, default: -> { "CURRENT_TIMESTAMP" }
        t.datetime :started_at
        t.datetime :finished_at
        t.json     :prep_summary
        t.integer  :candidate_count, default: 0
        t.json     :comparison
        t.string   :error
        t.timestamps null: false, default: -> { "CURRENT_TIMESTAMP" }
        # `owner`, `active_job_id` and `steps_state` arrive from the migrations
        # that add them, on purpose -- see the class comment.
      end
    end

    unless table_exists?(:candidates)
      create_table :candidates do |t|
        t.integer  :job_id, null: false
        t.string   :file, null: false                       # e.g. candidate_04.svg
        t.string   :preset
        t.string   :hierarchical
        t.integer  :filter_speckle
        t.boolean  :use_palette
        t.json     :sweep
        t.string   :layer_a, default: "pending"              # pass|fail|error|pending
        t.string   :layer_b, default: "pending"
        t.integer  :hard, default: 0
        t.integer  :advisory, default: 0
        t.json     :fidelity
        t.boolean  :passed, default: false
        t.string   :note
        t.datetime :created_at, default: -> { "CURRENT_TIMESTAMP" }
      end
    end

    unless table_exists?(:validations)
      create_table :validations do |t|
        t.integer  :job_id, null: false
        t.integer  :candidate_id
        t.string   :file, null: false                       # candidate file picked
        t.string   :state, default: "pending", null: false   # pending|running|done|error
        t.string   :runner_validation_id
        t.json     :manifest
        t.json     :jev_answers
        t.json     :jev_meta
        t.string   :error
        t.datetime :queued_at, default: -> { "CURRENT_TIMESTAMP" }
        t.datetime :finished_at
        t.datetime :created_at, default: -> { "CURRENT_TIMESTAMP" }
        # `owner` arrives from AddUsersAndOwnerIsolation.
      end
    end
  end
end
