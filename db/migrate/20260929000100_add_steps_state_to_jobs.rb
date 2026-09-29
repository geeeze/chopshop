# Execution progress for a job whose request is a STEP LIST (spec["steps"]).
#
# A long-lived request edits the row as it goes, so the record stays honest
# about a chain that was interrupted: which step was running, which had
# finished, and what each one produced. Additive and nullable — an existing job
# (a single-action job, i.e. every job row there is) simply has no state, and
# nothing reads it unless the spec carries a step list. Guarded like every other
# migration here, because a database built from schema.rb already has the column
# while schema_migrations may lack this version.
class AddStepsStateToJobs < ActiveRecord::Migration[8.1]
  def change
    add_column :jobs, :steps_state, :json unless column_exists?(:jobs, :steps_state)
  end
end
