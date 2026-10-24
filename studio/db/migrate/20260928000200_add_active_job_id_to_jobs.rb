# The Active Job id of the pending Solid Queue job, stored on the studio Job so
# a queued job can be discarded (removed from the queue) when the operator
# cancels it before its turn. Cleared meaninglessly once the job runs; a re-run
# simply overwrites it with the next enqueue's id.
class AddActiveJobIdToJobs < ActiveRecord::Migration[8.1]
  def change
    add_column :jobs, :active_job_id, :string
  end
end
