# The PROMPT LIBRARY: real, human-written prompts ingested from a public dataset,
# with the provenance and the coordinates that make each one more than a string.
#
# Why a table in this app rather than a file: the library is READ BY THREE
# THINGS that must not disagree — the LIBRARY page (browsed and searched), the
# Run Job form (a prompt is drawn from it and generated for real), and the JSON
# twin an agent reads. A JSON file cannot be filtered by SQL at that size, and a
# second copy of the dataset in another format is a second thing to keep in step.
#
# PROVENANCE IS COLUMNS, not prose: which dataset, under which licence, from
# which part of it. DiffusionDB's own metadata is what makes a row usable for
# generation — its authors' seed/step/guidance/sampler — and its `part` is what
# lets a reader go back and find the image the prompt produced.
#
# `x`/`y` are the dataset's own 2-D projection of prompt space, and `topic`/
# `phrase_root` the labels its authors derived from it. They are what the page's
# MAP is drawn from, so the map and the table are two readings of one row rather
# than two datasets.
#
# NO `owner` COLUMN, deliberately, and it is the one table here without one: a
# dataset slice is REFERENCE DATA shared by every user, like config/palettes.json
# — there is no user whose work it is, and scoping it to whoever happened to run
# the ingest would hide it from everybody else.
#
# Guarded on what it would create, in the style of CreateEvents: the repo's
# schema.rb is hand-maintained, so a database built from it and one that predates
# this migration both end up with the same table.
class CreatePromptSources < ActiveRecord::Migration[8.1]
  def change
    unless table_exists?(:prompt_sources)
      create_table :prompt_sources do |t|
        # --- provenance -------------------------------------------------------
        t.string :dataset, null: false            # "diffusiondb"
        t.string :licence                          # the dataset's own licence, as it states it
        t.string :attribution                      # who made it, and where a reader finds it
        t.string :part                             # the dataset's own shard id, e.g. "part-000001"
        t.string :image_name                       # the image this prompt produced, when known

        # --- the prompt -------------------------------------------------------
        t.text   :prompt, null: false
        t.string :prompt_sha                       # digest of the text: the row's identity under cleaning

        # --- the author's hyperparameters, as the dataset recorded them -------
        t.integer :seed
        t.integer :steps
        t.float   :guidance
        t.string  :sampler
        t.integer :width
        t.integer :height
        t.boolean :nsfw                            # the dataset's own safety flag

        # --- where it sits in prompt space -----------------------------------
        t.string :topic                            # the derived topic cluster, when one covers the point
        t.string :phrase_root                      # the most frequent phrase-tree root in the prompt
        t.float  :x                                # the dataset's own 2-D projection
        t.float  :y

        # Loose per-row detail that has no column of its own, so a reader can get
        # at it without a migration per field.
        t.json :meta, default: {}

        # Explicit, matching every other app table in schema.rb (the repo's schema
        # is hand-maintained, so the two must agree column for column).
        t.datetime :created_at, default: -> { "CURRENT_TIMESTAMP" }
        t.datetime :updated_at, default: -> { "CURRENT_TIMESTAMP" }
      end
      add_index :prompt_sources, :prompt_sha
      add_index :prompt_sources, :dataset
      add_index :prompt_sources, :topic
      add_index :prompt_sources, :phrase_root
      add_index :prompt_sources, :part
    end
  end
end
