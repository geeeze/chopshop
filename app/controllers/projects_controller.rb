# The container: Projects own the sources they load, the jobs they dispatch,
# the outputs the jobs return, and the tags applied to all four. The operator
# sees a workspace, and every read is scoped to the signed-in owner.
class ProjectsController < ApplicationController
  before_action :require_login
  before_action :set_project, only: %i[show edit destroy]

  # The Projects page — the container's index, not a reference page. It joins
  # nothing (no `head_alignment` / `responsive_head` registry required), and its
  # head is the standard `.page-head-row--stacked` layout pinned in CONTEXT.md.
  # The nav entry for Projects lives below BP (after BP in the nav row), so a
  # new entry at the end keeps the 6-entry row size unchanged.
  def index
    @projects = Project.for_owner(Current.user_handle).includes(:tags).order(name: :asc)
    @project_count = Project.for_owner(Current.user_handle).count
  end

  def show
    # A page-level read, not an agent POST, so no session-bound authenticity
    # is needed for the markup — the `show` action uses `require_login`, and
    # the row is `Owned`-scoped.
    @sources = @project.sources
    @jobs    = @project.jobs
    @outputs = @project.outputs
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
    # Scoped: a user can only load the container they own.
    @project = Project.for_owner(Current.user_handle).find(params[:id])
  rescue ActiveRecord::RecordNotFound => e
    redirect_to projects_path, alert: "Project not found."
  end

  def project_params
    params.require(:project).permit(:name, :is_test)
  end
end