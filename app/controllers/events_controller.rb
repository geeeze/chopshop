# The event log's read surface: the operator's own recorded human actions
# (stars, picks, deletes) as JSON, for a later learned-ranker phase to pull.
# Read-only and login-gated like every other authed route.
#
# Owner scoping is the Event model's Owned default_scope, not a filter here —
# so the isolation holds for every caller, this controller included, and one
# operator can never read another's training signal.
class EventsController < ApplicationController
  before_action :require_login

  DEFAULT_LIMIT = 200
  LIMIT_MAX = 1000

  def index
    events = Event.recent.limit(limit)
    events = events.of_kind(params[:event]) if params[:event].present?
    events = events.for_job(params[:job_id].to_i) if params[:job_id].present?
    render json: events.map { |e| event_json(e) }
  end

  private

  def limit
    n = params[:limit].to_i
    return DEFAULT_LIMIT if n <= 0
    [n, LIMIT_MAX].min
  end

  def event_json(event)
    {
      id: event.id, event: event.event, job_id: event.job_id,
      svg_sha: event.svg_sha, pos: event.pos, ranker: event.ranker,
      payload: event.payload, created_at: event.created_at
    }
  end
end
