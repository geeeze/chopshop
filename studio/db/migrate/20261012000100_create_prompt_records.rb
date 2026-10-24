class CreatePromptRecords < ActiveRecord::Migration[7.1]
  # The prompts an operator has filed, so the Run Job form can offer them back.
  #
  # Deduped on a DIGEST of the text, not on the text: a prompt is unbounded
  # (a composed or mashup prompt runs to hundreds of characters), and a unique
  # index over a long text column is not portable -- Postgres refuses a btree
  # entry past ~2704 bytes. The digest is what makes "remember this prompt"
  # an upsert instead of a pile of near-twins every time one is refined.
  def change
    create_table :prompt_records do |t|
      t.text :prompt, null: false
      t.string :fingerprint, null: false
      # Where the prompt came from: typed | dataset | mashup | composer. Null
      # is allowed so a record written by an older caller is still readable.
      t.string :source
      # The run it was used on. Nullable and not a foreign key: the record is
      # the operator's recall list, and it must outlive the job (jobs are
      # sweepable, a prompt library is not).
      t.integer :job_id
      t.integer :uses_count, null: false, default: 1
      t.datetime :last_used_at
      t.timestamps
    end

    add_index :prompt_records, :fingerprint, unique: true
    add_index :prompt_records, :last_used_at
  end
end
