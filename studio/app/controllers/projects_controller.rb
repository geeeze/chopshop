# The container: Projects own the sources they load, the jobs they dispatch,
# the outputs the jobs return, and the tags applied to all four. The operator
# sees a workspace, and every read is scoped to the signed-in owner.
class ProjectsController < ApplicationController
  before_action :require_login
  before_action :set_project, only: %i[show]

  # The Projects index — the app's root page. Lists all projects for the
  # signed-in operator, with a "New Project" action.
  def index
    @projects = Project.for_owner(Current.user_handle).includes(:tags).order(name: :asc)
    @project_count = Project.for_owner(Current.user_handle).count
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
  def show
    @jobs       = @project.jobs.recent.includes(:validations)
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

  def set_project
    @project = Project.for_owner(Current.user_handle).find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to projects_path, alert: "Project not found."
  end

  def project_params
    params.require(:project).permit(:name, :is_test)
  end
end