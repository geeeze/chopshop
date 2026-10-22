# frozen_string_literal: true

# The project picker's shared resolution — the one rule both HTML forms that
# file work into the Projects workspace follow: Run Job (JobsController) and
# the composite builder (CompositesController).
#
# A project-less creation is invisible where the workspace lists things — the
# Jobs index is per-project, and a compose run is recorded under its composite's
# project — so an HTML post must name a home: an existing project id, or a
# new-project name that makes the project first. JSON/agent posts may still
# omit it (the documented agent-api contract).
module ProjectPicker
  extend ActiveSupport::Concern

  private

  # Returns [project_id, error_or_nil]:
  #   - a normalised id when one was posted (Rails casts "__new__" — or any
  #     non-numeric junk — to 0, which is neither nil nor a project; ≤0 means
  #     "no project chosen", or it would file the work under a project that
  #     does not exist),
  #   - the created project's id when a name was posted with no id,
  #   - a refusal message when HTML posted neither,
  #   - nil with no error when JSON posted neither.
  # An id wins over a name when both are posted: the operator picked an
  # existing project and any stray name input is cleared on the client.
  def pick_project(raw_id, raw_name, what:)
    id = raw_id.to_i
    id = nil if id <= 0
    name = raw_name.to_s.strip

    if name.present? && id.blank?
      project = Project.new(name: name, is_test: false)
      return project.save ? [project.id, nil] :
        [nil, "New project not created: #{project.errors.full_messages.to_sentence}."]
    end

    if id.blank? && request.format.html?
      return [nil, "This #{what} needs a project: pick one in the Project field, " \
        "or choose \u201cCreate a new project\u201d and name it \u2014 a " \
        "project-less #{what} is listed nowhere under the Projects workspace."]
    end

    [id, nil]
  end
end
