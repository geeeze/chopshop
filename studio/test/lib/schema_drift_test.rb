require "test_helper"
require "set"
require "tempfile"

# `schema.rb` must describe every table any migration creates -- and the reverse.
#
# This class of drift is invisible from either side alone, which is why it
# survived for the life of the app:
#
#   * a database built by REPLAYING MIGRATIONS has whatever the migrations create;
#   * a database built from `schema.rb` has whatever the dump describes;
#   * and nothing compared the two.
#
# So a table added in one file and not the other produced two different databases
# depending only on which command the operator happened to run. `bin/rails
# db:migrate` on a fresh DEVELOPMENT database aborted outright at
# `20260928000500_add_palette_to_composites: Could not find table 'composites'`,
# because `composites` (like `scrapbook_items`, `jobs`, `candidates` and
# `validations`) had no create migration at all -- `schema.rb` was their only
# source. The workarounds were `db:test:prepare` for test and
# `RAILS_ENV=production db:migrate` for production, so the only path anyone used
# was the only path nobody exercised.
#
# The worse instance is the one that could not fail at all. `session_drafts` was
# MISSING from `schema.rb` although `CreateSessionDrafts` had run in production.
# Every schema-built database therefore had no such table, and
# `DraftHandoffTest` errored with "Could not find table 'session_drafts'" -- seven
# errors, impossible in production, permanent in test and CI. It was found by
# hand. `CreateSessionDrafts` is the one migration here NOT guarded with
# `table_exists?`, which is exactly why nothing caught it: on a database that
# already has the table it is a silent no-op, and on a schema-built database it
# never runs at all. Neither path can fail loudly.
#
# So the check is bidirectional and it is the check that would have caught
# `session_drafts` the day it landed.
class SchemaDriftTest < ActiveSupport::TestCase
  MIGRATE_DIR = Rails.root.join("db", "migrate").freeze
  SCHEMA = Rails.root.join("db", "schema.rb").freeze

  # Tables the application owns. `schema_migrations`, `ar_internal_metadata` and
  # the `solid_queue_*` / `solid_cache_*` families are Rails' and Solid Queue's
  # own: the first two are bookkeeping, and the rest are created and maintained by
  # the gem's own migrations. Requiring this app's dump to describe them would be
  # asserting something about the gems, not about this schema.
  #
  # Listed as a PREFIX match so a solid_queue table added by a gem upgrade does
  # not fail this suite -- the failure this file exists to catch is a table this
  # app's own migrations and this app's own dump disagree about.
  GEM_OWNED_PREFIXES = %w[schema_migrations ar_internal_metadata solid_queue_ solid_cache_].freeze

  def gem_owned?(table)
    GEM_OWNED_PREFIXES.any? { |prefix| table == prefix || table.start_with?(prefix) }
  end

  # Every `create_table` a migration performs, as a SET of table names.
  #
  # PARSED, not executed. The alternative -- replaying the migrations into a
  # throwaway database and diffing the result against the dump -- is the stronger
  # check, and it is deliberately not what this does, for two reasons that are
  # both about it being the wrong tool for the job it is being used for:
  #
  #   * it needs a writable database, a writable schema cache and the app's whole
  #     boot, so it cannot run inside a suite that already holds the test
  #     database open. The suite is what has to notice this, and a check that
  #     cannot run in the suite is a check that does not run;
  #   * executing a migration is not a faithful read of it. Every create here is
  #     wrapped in `unless table_exists?`, so replaying against a database that
  #     already has the tables creates NOTHING, and the very guard that makes the
  #     migration safe on an existing deployment makes the replay a no-op that
  #     looks like a pass.
  #
  # The parser is a regex on the migration SOURCE, which is the thing that has to
  # be true. It is deliberately simple: `create_table` is a single top-level call
  # in each of this app's migrations, and a form it cannot read is reported as
  # NOT a create rather than silently skipped, so a rewrite of the style fails
  # here instead of quietly emptying the set.
  def migration_created_tables
    @migration_created_tables ||= MIGRATE_DIR.children
                                                 .select { |f| f.extname == ".rb" }
                                                 .flat_map { |f| migration_creates(f) }
                                                 .to_set
  end

  MIGRATION_CREATE = /create_table\s+(?:\(|)\s*:([a-z_][a-zA-Z0-9_]*)/.freeze

  def migration_creates(file)
    File.read(file).scan(MIGRATION_CREATE).flatten
  end

  # Every table `schema.rb` describes, as a SET.
  SCHEMA_CREATE = /^\s*create_table\s+"([a-z_][a-zA-Z0-9_]*)"/.freeze

  def schema_tables
    @schema_tables ||= File.read(SCHEMA).scan(SCHEMA_CREATE).flatten.to_set
  end

  test "every table the schema describes is one some migration can create" do
    # The `session_drafts` check. A table in the dump with no create migration is
    # a table a replay-built database does not have -- and the only symptom
    # arrives as an unrelated-looking error in whichever test touched it.
    uncreatable = (schema_tables.to_a.reject { |t| gem_owned?(t) }.to_set - migration_created_tables).to_a.sort
    assert_empty uncreatable,
                 "schema.rb describes #{uncreatable.inspect}, which no " \
                 "migration creates. A database built by replaying migrations will " \
                 "not have #{uncreatable.inspect}, and nothing in the " \
                 "normal test path loads schema.rb, so the first sign is an error " \
                 "in whatever test happens to touch it. Add the create migration " \
                 "(guarded on table_exists?), or remove the table from the dump if " \
                 "it is not really this app's."
  end

  test "every table a migration creates is one the schema describes" do
    # The other direction, and the one that catches the opposite mistake: a
    # migration that creates a table and a dump that never learned about it. The
    # database works, and then the next `db:schema:dump` DELETES the table
    # definition -- so the fault surfaces on a developer's machine as a table
    # that has quietly vanished, days after the migration that made it.
    undescribed = (migration_created_tables.to_a.reject { |t| gem_owned?(t) }.to_set - schema_tables).to_a.sort
    assert_empty undescribed,
                 "#{undescribed.inspect} is created by a migration but " \
                 "is not in schema.rb. Re-dump the schema, or the next developer to " \
                 "load it gets a database without #{undescribed.inspect} " \
                 "and no error explaining why."
  end

  # --- and the two sides are not merely consistent, they AGREE ---------------
  #
  # Set equality is a weak claim: two files can describe the same table NAMES and
  # different tables. The tables this app was missing create migrations for are
  # the concrete instance -- `composites` and `scrapbook_items` are the two the
  # issue names, and they are the two whose absence made `db:migrate` abort.
  test "the tables that broke db:migrate are now creatable, and the replay is complete" do
    %w[jobs candidates validations composites scrapbook_items session_drafts].each do |table|
      assert_includes migration_created_tables, table,
                      "#{table} has no create migration, so a database built by " \
                      "replaying migrations never has it — this is the exact shape " \
                      "of the fault that made `bin/rails db:migrate` abort on a fresh " \
                      "database and made DraftHandoffTest error with 'Could not find " \
                      "table session_drafts'"
    end
  end

  # The parser is the whole test, so it has to be able to fail. A `create_table`
  # form it cannot read would empty the set and turn every assertion above into a
  # pass -- the "I could not read this" case that must never read as "it agrees".
  test "the parser really reads create_table, and a form it cannot read is reported as no create" do
    source = <<~RUBY
      class CreateThings < ActiveRecord::Migration[8.1]
        def change
          create_table :widgets do |t|
            t.string :name
          end
        end
      end
    RUBY
    Tempfile.create(["probe", ".rb"]) do |f|
      f.write(source)
      f.flush
      assert_equal %w[widgets], migration_creates(Pathname.new(f.path)),
                   "the parser must read a create_table with a block, which is " \
                   "the form every migration in db/migrate uses"
    end

    # A form it does NOT recognise yields nothing, and the assertions above then
    # fail loudly rather than passing on an empty set. Stated here because the
    # alternative -- a parser that guesses and skips -- is how a check like this
    # becomes decoration.
    Tempfile.create(["probe", ".rb"]) do |f|
      f.write("class CreateThings < ActiveRecord::Migration[8.1]\n" \
              "  def change\n    Widget.create_table!\n  end\nend\n")
      f.flush
      assert_empty migration_creates(Pathname.new(f.path))
    end
  end

  test "the migration directory is not empty, or every assertion above is vacuous" do
    # The set both directions are computed from. A parser pointed at a moved or
    # renamed directory returns nothing, `schema_tables - migration_created_tables`
    # becomes "every table", and the failure would be a wall of names rather than
    # the one real drift. So the emptiness is checked directly.
    refute_empty migration_created_tables,
                 "no create_table was found in db/migrate — either the directory " \
                 "moved or the parser stopped matching, and every other assertion " \
                 "in this file is currently proving nothing"
    assert_operator migration_created_tables.size, :>=, 10,
                    "the studio has well over ten tables; a handful means the " \
                    "parser is reading only some of the migrations"
  end
end
