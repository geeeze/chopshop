# The host's own timeseries: one row a minute of CPU, memory and swap, read from
# /proc by HostSample and written by the recurring task in config/recurring.yml.
#
# NO `owner` COLUMN, deliberately: this is the box's history, not a user's work,
# so it is the second table here without an owner (prompt_sources is the first).
# Two operators on one machine read the same chart.
#
# `cpu_total` / `cpu_idle` are the raw CUMULATIVE counters the sample was taken
# from. A CPU percentage is a delta between two samples, so the counters have to
# be stored with the reading — the percentage alone cannot be re-differenced, and
# a percentage computed against a sample taken an hour ago would describe an hour
# while being drawn as one point.
#
# `cpu_pct`, `mem_pct` and `swap_pct` are all NULLABLE and that is the contract:
# nil is "not measured" (the first sample has no predecessor; a box with no swap
# has nothing to report), which is a different statement from 0.
#
# Guarded on what it would create, in the same style as CreateEvents:
# schema.rb is hand-maintained and carries this table too, so a database built
# from schema.rb already has it and `migrate` is a no-op there.
class CreateHostSamples < ActiveRecord::Migration[8.1]
  def change
    return if table_exists?(:host_samples)

    create_table :host_samples do |t|
      t.datetime :captured_at, null: false
      t.float    :cpu_pct
      t.bigint   :cpu_total
      t.bigint   :cpu_idle
      t.integer  :mem_total_mb
      t.integer  :mem_used_mb
      t.float    :mem_pct
      t.integer  :swap_total_mb
      t.integer  :swap_used_mb
      t.float    :swap_pct
      t.float    :load1
      # Only created_at: a sample is written once and never updated, so an
      # updated_at column would be a field that is always equal to the other one.
      t.datetime :created_at, default: -> { "CURRENT_TIMESTAMP" }
    end
    add_index :host_samples, :captured_at
  end
end
