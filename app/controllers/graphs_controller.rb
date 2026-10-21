# GET /graph -- the studio's own records as one shape (#96, facelift 4/4).
#
# One page and one JSON document answering "what does this studio look like":
# every project, job, candidate and proof the signed-in owner can see, joined by
# the containment and pick lines between them. Read-only, and cheap enough to
# fetch on every load: a bounded walk of the owner's own rows, not a join of
# whole tables.
#
# HTML and JSON on ONE route, the way the studio already serves its JSON
# (`GET /jobs/:id` and `/jobs/:id.json`, `GET /audit` and `/audit.json`): `/graph`
# renders the page, `/graph.json` renders the document. No `/api` namespace -- the
# kb's `/api/graph` is the SHAPE this follows, not a path mandate.
#
# Login-gated like every other authed route, and for two reasons rather than one:
# the nodes are facts about a private deployment's data AND every node's art URL
# is one of this app's own login-gated file routes, so the graph cannot be
# fetched without a session that can also fetch the artwork it draws.
class GraphsController < ApplicationController
  before_action :require_login

  def show
    document = GraphData.build

    respond_to do |format|
      format.html { render :show }
      format.json { render json: document }
    end
  end
end
