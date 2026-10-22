class AddPrepExpandToJobs < ActiveRecord::Migration[7.1]
  def change
    # The expanded-prep bench report the runner returns in GET /jobs/:id.
    # Stored as JSON so the bench's own shape (filters / tune / node_reduce
    # sub-reports) is preserved without a migration per bench. NULL when the
    # job did not ask for the bench (spec.print.prep_expand was off).
    add_column :jobs, :prep_expand, :json
  end
end
