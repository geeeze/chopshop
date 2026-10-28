class AddEpistemicFlagsToValidations < ActiveRecord::Migration[8.1]
  def change
    # The epistemic flags (#9): a proof's FINDINGS and its JEV ANSWERS are the
    # studio's claim layer, and until now they were accept-as-stated. A claim
    # can be marked needs_factcheck (nobody has checked it) or disputed (two
    # readings disagree), and the audit counts them so the debt is visible.
    #
    # The flag lives HERE, on the proof row, rather than inside `manifest` or
    # `jev_answers`: both of those are the RUNNER's and the ANNOTATOR's own
    # records, and rewriting a finding's hash inside the manifest would put a
    # studio opinion into a file the pipeline authored. A per-proof column is
    # the one place the studio can hold its own verdict without forging the
    # source's.
    #
    # Both default false and are NOT NULL: the absence of a flag is "accepted",
    # which is the state every row already is in, so a default of false keeps
    # existing rows honest rather than leaving them NULL.
    add_column :validations, :needs_factcheck, :boolean, default: false, null: false
    add_column :validations, :disputed, :boolean, default: false, null: false
  end
end
