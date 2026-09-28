# The candidate-triage LEARNING SIGNAL: one row for every human action the
# studio observes (favourited, unfavourited, picked, deleted), for a learned
# ranker to train on later.
#
# Two shapes are deliberate, both copied from scrapbook_items:
#
#   * NO foreign key to jobs. `job_id` is PROVENANCE ONLY — it says which run
#     an action came from, never a dependency. That is the whole requirement:
#     deleting a job must not take its training signal with it, so an event row
#     outlives the job it describes.
#   * `owner` is the signed-in user's handle, stamped at create and used to
#     scope every read, exactly as jobs/scrapbook_items/composites do.
#
# `svg_sha` is the artifact's sha256, `pos` the artifact's 1-based rank on the
# ordered candidate list when the action was made on one, and `ranker` which
# ranker produced that order. `payload` carries the loose per-action detail
# (the artifact's name/kind, the runner state at delete time) so the columns a
# ranker trains on stay stable while the context stays available.
#
# `sha256` is also added to scrapbook_items: the studio's "checksum at
# creation" — what a favourite actually stored, recorded when it stored it.
#
# Guarded on what it would create, in the same style as
# AddUsersAndOwnerIsolation: scrapbook_items and composites have no create
# migration of their own (schema.rb is their source), so a database built from
# schema.rb already carries the column and a database that predates it gains it
# here. `migrate` is a no-op on the former and correct on the latter.
class CreateEvents < ActiveRecord::Migration[8.1]
  def change
    unless table_exists?(:events)
      create_table :events do |t|
        t.string  :owner
        t.string  :event, null: false
        t.integer :job_id                            # provenance only — survives the job's destroy
        t.string  :svg_sha
        t.integer :pos
        t.string  :ranker
        t.json    :payload, default: {}
        # Explicit, matching every other app table in schema.rb (the repo's
        # schema is hand-maintained, so the two must agree column for column).
        t.datetime :created_at, default: -> { "CURRENT_TIMESTAMP" }
        t.datetime :updated_at, default: -> { "CURRENT_TIMESTAMP" }
      end
      add_index :events, :owner
      add_index :events, :job_id
      add_index :events, :event
    end

    if table_exists?(:scrapbook_items) && !column_exists?(:scrapbook_items, :sha256)
      add_column :scrapbook_items, :sha256, :string
    end
  end
end
