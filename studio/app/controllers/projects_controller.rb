# The container: Projects own the sources they load, the jobs they dispatch,
# the outputs the jobs return, and the tags applied to all four. The operator
# sees a workspace, and every read is scoped to the signed-in owner.
class ProjectsController < ApplicationController
  before_action :require_login
  before_action :set_project, only: %i[show]

  # The Projects index — the app's root page. Lists all projects for the
  # signed-in operator, with a "New Project" action.
  #
  # `?q=<text>` narrows the list: the missing-record page links here with the
  # stem it named (issue #4) and the index did not read the parameter, so the
  # link landed on the whole workspace. The match is a CASE-INSENSITIVE
  # substring over the project's NAME — the column the operator reads, and the
  # only name a project row carries (a job's stem is a run's identity, not a
  # project's, so matching it here would answer a different question). A blank
  # `q` is no filter at all, so the plain page is unchanged.
  def index
    q = params[:q].presence
    @query = q
    @projects = Project.for_owner(Current.user_handle).includes(:tags).order(name: :asc)
    @projects = @projects.where("name LIKE ? ESCAPE '\\'", "%#{sanitize_like(q)}%") if q
    @project_count = @projects.count
    # The job previews that make up each project card's thumbnail, grouped by
    # project — ONE query, not an N+1 per card. Only jobs that HAVE something to
    # show earn pixels; a project with nothing falls back to the scissor.
    @project_previews =
      if @projects.empty?
        {}
      else
        Job.where(project_id: @projects.map(&:id)).includes(:validations)
           .order(created_at: :desc).to_a
           .select { |j| j.preview_file.present? }
           .group_by(&:project_id)
      end
  end

  # The project workspace: shows the project's jobs, composites, and outputs.
  # This is the main working page — jobs and composites are created within
  # a project, and outputs return to the project that originated them.
  #
  # `?state=<job state>` narrows the RUN LIST, and the select that sets it
  # carries the live distribution (#10): `@state_counts` is the project's own
  # group-by and `@jobs` is that SAME scope narrowed by the chosen value, so an
  # option's count and the rows it produces cannot disagree — one resolution
  # site, the kb's `per (294)` idiom. A blank or unknown value is no filter at
  # all: a stale bookmark cannot silently empty the list, and the plain page is
  # exactly what it was.
  def show
    @state = params[:state].presence
    @state = nil unless Job::STATES.include?(@state)

    jobs = @project.jobs.recent
    # Grouped from the unfiltered scope, ordered by nothing: a GROUP BY with
    # the list's ORDER BY still attached makes SQLite pick an arbitrary
    # created_at for the group, and the counts are the only thing wanted here.
    @state_counts = jobs.reorder(nil).group(:state).count
    @jobs_total   = @state_counts.values.sum
    @jobs         = (@state ? jobs.where(state: @state) : jobs).includes(:validations)
    @jobs_count   = @state ? @state_counts.fetch(@state, 0) : @jobs_total

    @composites = @project.composites.recent
    @outputs    = @project.outputs
    @sources    = @project.sources
  end

  def new
    @project = Project.new
  end

  def create
    @project = Project.new(project_params)
    if @project.save
      redirect_to @project, notice: "Project #{project_params[:name]} created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  # A LIKE needle with `%` and `_` escaped, so the text the operator typed is
  # searched for literally — a project whose name contains `%` is findable,
  # and a stray `%` cannot widen the match to everything. The same rule the
  # prompt-library search applies (`DatasetsController#filtered`).
  def sanitize_like(text)
    text.to_s.gsub(/[\\%_]/) { |c| "\\#{c}" }
  end

  def set_project
    @project = Project.for_owner(Current.user_handle).find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to projects_path, alert: "Project not found."
  end

  def project_params
    params.require(:project).permit(:name, :is_test)
  end
end