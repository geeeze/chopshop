# `scrapbook_items`, whose only source until now was `schema.rb`.
#
# The third of the three table-creating migrations this app never had; see
# `CreateStudioCoreTables` for the whole shape of the problem and
# `CreateComposites` for why each of these is dated to run first and is guarded.
#
# GUARDED, and dated so it runs first on a fresh database.
#
# `sha256` is NOT created here: `CreateEvents` adds it to this table, and
# creating it here as well would make that migration's guarded `add_column` a
# duplicate. Reconstructed as the dump first described it, then built forward.
#
# Two columns carry meaning that is easy to lose in a transcription, so they are
# stated here rather than left to the reader:
#
#   * `owner` is NULLABLE and `job_id` has NO FOREIGN KEY. Both are deliberate.
#     The item is a COPY of bytes into `storage/scrapbook/`, so it must outlive
#     the job it came from; a foreign key would cascade the copy away the moment
#     the job was deleted, which is the opposite of what the scrapbook is for.
#     `job_id` is provenance, not a relationship the database enforces.
#   * `sha256` is the identity of the stored bytes, so the same file saved twice
#     is one item rather than two.
class CreateScrapbookItems < ActiveRecord::Migration[8.1]
  def change
    return if table_exists?(:scrapbook_items)

    create_table :scrapbook_items do |t|
      t.string   :name, null: false                # display name (candidate_06.svg, proof_04.png, …)
      t.string   :kind, null: false                # source | invert | candidate | proof | upload
      t.string   :file, null: false                # stored basename under storage/scrapbook/
      t.string   :owner                             # nullable: one operator today, pivot-ready
      t.integer  :job_id                            # provenance only — survives the job's deletion
      t.timestamps null: false, default: -> { "CURRENT_TIMESTAMP" }
      # `sha256` — the digest of the stored bytes — arrives from CreateEvents.
    end
  end
end
