# GET /audit -- the studio's data debt, counted (issue #95, facelift 3/4).
#
# One page and one JSON document answering "how complete is our data": every
# structural gap the studio's own tables expose, per class and per project, with
# the literal id list behind each count. Read-only, and cheap enough to poll --
# the counts are aggregate queries and the id lists are `pluck`s, never a walk
# over whole tables.
#
# HTML and JSON on ONE route, the way the studio already serves its JSON
# (`GET /jobs/:id.json`): `/audit` renders the page, `/audit.json` renders the
# document. No `/api` namespace -- the kb's `/api/audit` is the SHAPE this
# follows, not a path mandate.
#
# The page's own filters are read-only GETs on the same route:
#
#   GET /audit?gap=jobs.missing_runner_stem  the id list behind ONE gap
#   GET /audit?project=3                     the unresolved ids in ONE project
#
# Login-gated like every other authed route: the counts are facts about a
# private deployment's data, and the ids name records in it.
class AuditController < ApplicationController
  before_action :require_login

  def show
    report = AuditGaps.report

    respond_to do |format|
      format.html do
        @report = report
        @gap_key = params[:gap].presence
        @project_id = params[:project].presence
        # A filter renders the LIST behind a count rather than the whole page.
        # Both are recomputed here from the same relations the counts came from,
        # so a filtered list cannot disagree with the number it was reached from.
        @gap_rows = @gap_key ? AuditGaps.rows_for(@gap_key) : nil
        @project_rows = @project_id ? AuditGaps.rows_in_project(@project_id) : nil
        @project = @project_id ? Project.find_by(id: @project_id.to_i) : nil
        render :show
      end
      format.json { render json: report }
    end
  end
end
