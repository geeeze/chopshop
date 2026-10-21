require "test_helper"
require "set"

# GET /graph -- the studio's own records as one shape (#96, facelift 4/4).
#
# The contracts pinned here:
#
#   * the ENGINE GATE -- app/javascript/graph.js is handed to a real JS parser
#     (`node --check`), and the settle/lifetime rules are pinned at the source
#     level: the sim STOPS when alpha settles, re-arms only through kick(), and
#     bails when the SVG leaves the document; the repulsion force AND the
#     per-tick displacement are both capped; the O(n^2) pass sees only visible
#     nodes; radii are rescaled on every fit/pan/zoom; labels are textContent.
#     A rule that is only described in a comment is not a rule.
#   * the GATE -- an anonymous caller is bounced to /login on both shapes, and
#     the controller declares it at the source level.
#   * the SHAPE -- the JSON document is exactly {nodes, edges}, and every node
#     carries the documented fields, so a consumer written against this shape
#     keeps reading it.
#   * the COUNTS -- asserted against SEEDED rows and against the models' own
#     owner-scoped counts, never against a hardcoded total.
#   * the NAV TRAP -- the graph is reached from the FOOTER, beside the audit
#     pill, and the sticky header's link row does not grow.
#   * the LABEL RULE -- a record's name reaches the DOM only through
#     textContent, so a name carrying a tag renders as the text it is.
#
# The fixtures are built so that each entity class, both edge kinds, a state
# ring, an empty marker and a proof's art are all present and individually
# nameable.
class GraphTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  GRAPH_JS = Rails.root.join("app/javascript/graph.js").read(encoding: "UTF-8")

  def sign_in
    post login_path, params: { password: "test-password" },
                     headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  end

  def page(path)
    get path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  end

  def graph_json
    get "/graph.json", headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    assert_equal "application/json", response.media_type
    JSON.parse(response.body)
  end

  def css_without_comments
    Rails.root.join("app/assets/stylesheets/application.css").read
         .gsub(%r{/\*.*?\*/}m, "")
  end

  # The fixture: one project with one done job, one passed candidate and one
  # finished proof; one errored job with nothing traced; one project that never
  # ran. Every assertion below names the rows it expects -- nothing is a total.
  def seed_graph
    project = Project.create!(name: "graph-proj-#{rand(1_000_000)}", is_test: false)
    job = project.jobs.create!(name: "graph-job-#{rand(1_000_000)}",
                               state: "done", source_kind: "svg",
                               input_path: "/data/graph.svg", stem: "graph",
                               runner: "mock", finished_at: Time.current)
    candidate = job.candidates.create!(file: "candidate_01.svg", preset: "bw",
                                       layer_a: "done", layer_b: "done",
                                       hard: 0, passed: true)
    proof = job.validations.create!(file: "candidate_01.svg", state: "done",
                                    candidate_id: candidate.id,
                                    manifest: { "proof" => "proof_01.png" })

    error_job = Job.create!(name: "graph-err-#{rand(1_000_000)}", state: "error",
                            source_kind: "svg", input_path: "/data/err.svg",
                            stem: "err", runner: "mock",
                            finished_at: Time.current, error: "boom")
    empty_project = Project.create!(name: "graph-empty-#{rand(1_000_000)}",
                                    is_test: false)

    { project: project, job: job, candidate: candidate, proof: proof,
      error_job: error_job, empty_project: empty_project }
  end

  # The owner-scoped counts straight from the models, so the document's totals
  # are compared against the records rather than against a number typed here.
  # Candidates have no owner column: they are counted through the owner's jobs.
  def model_counts
    {
      "project" => Project.count,
      "job" => Job.count,
      "candidate" => Candidate.where(job_id: Job.select(:id)).count,
      "proof" => Validation.where(job_id: Job.select(:id)).count
    }
  end

  def node(body, id)
    body["nodes"].find { |n| n["id"] == id }
  end

  # ============================================================ the engine gate

  test "the engine file parses as JavaScript" do
    require "open3"
    _out, status = Open3.capture2e("node", "--check", "-") do |stdin|
      stdin.write(GRAPH_JS)
    end
    assert status.success?, "graph.js must parse as JavaScript"
  end

  test "the engine has no dependencies of its own" do
    refute_match(/^\s*import /, GRAPH_JS, "the engine must stand alone: no imports")
    refute_match(/^\s*export /, GRAPH_JS, "and no exports -- it is a side-effect module")
    refute_match(/require\(/, GRAPH_JS)
  end

  # ---- the settle / lifetime rules, one pin per rule --------------------

  test "the simulation stops when alpha settles, and re-arms only through kick" do
    # The decay and the exit threshold are the two halves of "stops when
    # settled". A loop with no threshold never stops; a threshold with no decay
    # stops immediately.
    assert_match(/state\.alpha \*= 0\.975/, GRAPH_JS,
                 "the alpha decay is the settle clock")
    assert_match(/if \(state\.alpha > 0\.02 \|\| state\.drag\)/, GRAPH_JS,
                 "the loop exits below 0.02 and stays out")
    assert_match(/state\.running = false;/, GRAPH_JS,
                 "and the running flag is cleared, so nothing is left looping")

    # kick() is the only DOOR into the loop, and the loop re-arms itself exactly
    # once -- so the file holds exactly two frame requests: the door, and the
    # self-re-arm. A third would be a second door, i.e. a permanent loop.
    assert_match(/function kick\(/, GRAPH_JS)
    assert_match(/state\.alpha = Math\.max\(state\.alpha, a === undefined \? 0\.6 : a\)/,
                 GRAPH_JS, "kick() re-heats alpha before it asks for a frame")
    assert_equal 2, GRAPH_JS.scan(/window\.requestAnimationFrame\(/).size,
                 "two frame requests: kick()'s door and the loop's own re-arm"
    # The re-arm is the GUARDED branch, not a bare call at the end of the loop:
    # a bare re-arm would run even below the threshold, which is a permanent loop.
    assert_match(/if \(state\.alpha > 0\.02 \|\| state\.drag\) \{\s*\n\s*window\.requestAnimationFrame\(loop\);/,
                 GRAPH_JS, "the loop re-arms only while alpha is above the threshold")
    # And no timer of any kind: a setInterval is the permanent loop this file
    # exists to avoid, and it would keep running after the tab is hidden.
    refute_match(/setInterval/, GRAPH_JS)
    refute_match(/setTimeout\(loop/, GRAPH_JS)
  end

  test "the loop bails when the SVG leaves the document" do
    # A Turbo body swap mid-simulation removes the SVG; without this the loop
    # keeps requesting frames against a detached node forever.
    assert_match(/if \(!document\.body\.contains\(svg\)\) \{/, GRAPH_JS)
    assert_match(/state\.running = false;\s*\n\s*return;/m, GRAPH_JS,
                 "and it clears the running flag on the way out")
  end

  test "the repulsion force AND the per-tick displacement are both capped" do
    assert_match(/var FMAX = 6;/, GRAPH_JS,
                 "the force cap: near-coincident nodes otherwise get a huge kick")
    assert_match(/var STEP_MAX = 30;/, GRAPH_JS,
                 "AND the displacement clamp: a force cap alone lets a velocity " \
                 "accumulate and a node still jumps off the layout in one frame")
    assert_match(/Math\.max\(-STEP_MAX, Math\.min\(STEP_MAX, n\.vx \* state\.alpha\)\)/,
                 GRAPH_JS, "the clamp is applied to the position step, not the force")
  end

  test "only visible nodes join the O(n^2) pair pass" do
    # The filter must make the FRAME cheaper, not just the picture smaller.
    assert_match(/var live = state\.nodes\.filter\(visible\);/, GRAPH_JS)
    pair_pass = GRAPH_JS[/function tick\(\).*?\n  \}/m]
    refute_nil pair_pass, "the tick function must be present"
    assert_includes pair_pass, "live[i]"
    assert_includes pair_pass, "live[j]"
    refute_includes pair_pass, "state.nodes[i]",
                    "the pair pass must iterate the VISIBLE list, not every node"
  end

  test "node radii and stroke widths are rescaled on fit, pan and zoom" do
    assert_match(/function rescale\(\)/, GRAPH_JS)
    # rescale() is called from every path that changes the view: the initial draw
    # (the opening viewBox), the fit at rest, a drag-pan, and a wheel-zoom.
    # Missing one is a graph whose dots shrink to nothing as soon as the operator
    # touches it.
    assert_equal 4, GRAPH_JS.scan(/rescale\(\);/).size,
                 "rescale() must run on the initial draw, the settle fit, a pan and a zoom"
    assert_match(/state\.view\[2\] \/ 1100/, GRAPH_JS,
                 "the scale factor is derived from the viewBox width")
  end

  test "labels are textContent, never markup" do
    # A record's name is DATA: the studio's records are named by their operators,
    # and a name is not markup. The engine must never assemble a node's name into
    # an HTML string, so a name carrying a tag renders as the text it is.
    refute_match(/innerHTML/, GRAPH_JS,
                 "no markup assembly anywhere in the engine -- a name is data")
    assert_match(/label\.textContent = n\.name;/, GRAPH_JS)
    assert_match(/name\.textContent = node\.name;/, GRAPH_JS,
                 "the details panel's name is set the same way")
  end

  test "nodes are focusable and Enter opens the record" do
    assert_match(/g\.setAttribute\("tabindex", "0"\)/, GRAPH_JS)
    assert_match(/g\.setAttribute\("role", "link"\)/, GRAPH_JS)
    assert_match(/ev\.key === "Enter"/, GRAPH_JS)
    assert_match(/window\.location\.href = g\._node\.url;/, GRAPH_JS,
                 "Enter navigates to the record the node was drawn from")
  end

  test "the engine reads the same radii as the server publishes" do
    # A radius the server and the view disagree about is a node drawn at the
    # wrong size. Read both constants and compare them, rather than trusting
    # either side's comment.
    server = GraphData::RADIUS
    js = GRAPH_JS[/var RADIUS = \{[^}]*\}/]
    refute_nil js, "the engine declares its own radius table"
    js.each_line do |line|
      next unless line =~ /(\w+):\s*(\d+)/
      type = Regexp.last_match(1)
      radius = Regexp.last_match(2).to_i
      assert server.key?(type), "#{type} is not an entity class the server knows"
      assert_equal server[type], radius,
                   "#{type}: the engine and GraphData::RADIUS disagree"
    end
    assert_equal server.keys.sort, %w[candidate job proof project].sort
  end

  test "the placeholder is an SVG data URI, and the artwork is a URL set as an attribute" do
    assert_match(/data:image\/svg\+xml/, GRAPH_JS,
                 "a node without artwork gets the data-URI placeholder")
    assert_match(/img\.setAttribute\("href", n\.art \|\| PLACEHOLDER\)/, GRAPH_JS,
                 "the artwork is an href on an <image>, never parsed as markup")
    assert_match(/addEventListener\("error"/, GRAPH_JS,
                 "a file that is gone drops the image rather than showing a broken one")
  end

  # ============================================================== the page

  test "the page carries the stage, the controls and the details panel" do
    seed_graph
    sign_in
    doc = page("/graph")

    assert_equal "Graph", doc.at_css("h1.section-title .gradient-text")&.text&.strip
    assert doc.at_css("[data-graph-root]"), "the engine's mount point"
    assert doc.at_css("#gsvg"), "the SVG the nodes are drawn into"
    assert doc.at_css("#gedges"), "the edge layer"
    assert doc.at_css("#gnodes"), "the node layer"

    %w[gfind gnode-list ghops glabels grelax gfit gcount gdetails-body].each do |id|
      refute_nil doc.at_css("##{id}"), "##{id} is a control the engine binds to"
    end

    # One checkbox per ENTITY CLASS, all on by default.
    boxes = doc.css("input[data-gtype]")
    assert_equal %w[project job candidate proof], boxes.map { |b| b["data-gtype"] },
                 "the kind filter is the four entity classes"
    assert boxes.all? { |b| b["checked"] }, "every kind is shown until it is turned off"

    # The JSON twin is the page head's single secondary action.
    json_link = doc.at_css("a.head-action[href='#{graph_path(format: :json)}']")
    refute_nil json_link, "the page head links to the JSON shape"
    assert_equal "JSON", json_link.text.strip
  end

  test "the graph is reached from the footer, and the header nav does not grow" do
    sign_in
    doc = page(root_path)

    pill = doc.at_css(".footer-demo[href='#{graph_path}']")
    refute_nil pill, "the footer carries the graph pill, beside the audit one"
    assert_equal "graph", pill.text.strip

    # The sticky header is the WORKING path and holds a fixed link row.
    labels = doc.css("nav.topbar .nav-links a").map { |a| a.text.strip }
    refute_includes labels, "GRAPH", "the graph is not a header entry"
    refute_includes labels, "Graph"
    assert_equal "BP", labels.last, "and the row is unchanged: oldest to newest"
  end

  test "an anonymous visitor is offered no graph pill" do
    doc = page(login_path)
    assert_nil doc.at_css(".footer-demo[href='#{graph_path}']"),
               "the bar renders on /login, and the graph is this owner's records"
  end

  test "the stylesheet gives the class dot and the state ring separate colours" do
    css = css_without_comments

    # The class dot: one token per entity class.
    { "project" => "var(--secondary)", "job" => "var(--primary)",
      "candidate" => "var(--accent)", "proof" => "var(--text-tertiary)" }.each do |type, token|
      rule = css[/\.g-node--#{type}\s+\.g-body \{[^}]*\}/]
      refute_nil rule, ".g-node--#{type} .g-body must be styled"
      assert_includes rule, "fill: #{token}", "#{type}'s class colour is #{token}"
    end

    # The state ring: the studio's OWN state tokens, and never a class colour.
    { "running" => "var(--state-running-fg)", "error" => "var(--state-error-fg)",
      "fail" => "var(--band-fail-fg)", "pass" => "var(--band-pass-fg)" }.each do |state, token|
      rule = css[/\.g-node\[data-state="#{state}"\]\s+\.g-halo \{[^}]*\}/]
      refute_nil rule, "the #{state} state must colour the ring"
      assert_includes rule, "stroke: #{token}"
    end

    # A `fail` candidate is red (a hard gate fired) while an `error` JOB is amber
    # (a run broke) -- both are the studio's own tokens, and they are different
    # colours on purpose. Asserting both directions keeps a merge honest.
    candidate_fill = css[/\.g-node--candidate\s+\.g-body \{[^}]*\}/][/fill: ([^;]+)/, 1].strip
    error_ring = css[/\.g-node\[data-state="error"\]\s+\.g-halo \{[^}]*\}/][/stroke: ([^;]+)/, 1].strip
    refute_equal candidate_fill, error_ring,
                   "a failed candidate and an errored job are different colours by design"

    # The containment edge is dashed; the pick edge is not.
    assert_match(/\.g-edge--parent \{[^}]*stroke-dasharray: 3 3/m, css)
    refute_match(/\.g-edge--proof \{[^}]*stroke-dasharray/m, css)

    # The stage has a real height -- an SVG with no CSS box is 300x150.
    assert_match(/#gsvg \{[^}]*height: clamp\(/m, css)
    # The layout collapses rather than squeezing the SVG into a strip.
    assert_match(/@media \(max-width: 1100px\) \{\s*\.graph-layout \{ grid-template-columns: minmax\(0, 1fr\); \}/,
                 css)
  end

  # =========================================================== the endpoint

  test "an anonymous caller is bounced to login on both shapes" do
    get "/graph", headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
    assert_equal "/login", URI.parse(response.location).path

    get "/graph.json", headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
    assert_equal "/login", URI.parse(response.location).path
  end

  test "the controller declares the login gate at the source level" do
    src = Rails.root.join("app/controllers/graphs_controller.rb").read
    assert_match(/before_action :require_login/, src)
  end

  test "GET /graph is one route serving HTML and JSON" do
    route = Rails.application.routes.routes.find do |r|
      r.defaults[:controller] == "graphs" && r.defaults[:action] == "show"
    end
    refute_nil route, "GET /graph must be routed"
    assert_equal "GET", route.verb
    assert_equal "/graph(.:format)", route.path.spec.to_s
    assert_nil route.defaults[:format],
               "HTML is the default shape, so the format is not baked into the route"

    sign_in
    get "/graph", headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    assert_includes response.media_type, "text/html"
    assert_equal "/graph", graph_path
  end

  test "the document is exactly {nodes, edges}" do
    seed_graph
    sign_in
    body = graph_json

    assert_equal %w[edges nodes].sort, body.keys.sort,
                 "the shape is {nodes, edges} and nothing else"
    assert body["nodes"].is_a?(Array)
    assert body["edges"].is_a?(Array)

    body["nodes"].each do |n|
      assert_equal %w[art empty id name state tier type url].sort, n.keys.sort,
                   "#{n['id']}: a node carries exactly the documented fields"
    end
    body["edges"].each do |e|
      assert_equal %w[from kind to].sort, e.keys.sort
    end
  end

  test "a seeded fixture's graph is counted from the records, not assumed" do
    seed = seed_graph
    sign_in
    body = graph_json

    # The totals, read off the models' own owner-scoped counts.
    by_type = body["nodes"].group_by { |n| n["type"] }.transform_values(&:size)
    assert_equal model_counts, by_type,
                 "one node per record: the counts come from the tables, not a literal"

    # The seeded rows, by name.
    project = node(body, "project:#{seed[:project].id}")
    refute_nil project
    assert_equal seed[:project].name, project["name"]
    assert_equal "A", project["tier"], "a project is tier A"
    assert_equal "project", project["type"]
    assert_equal project_path(seed[:project]), project["url"]
    assert_nil project["state"], "a project is a container: it has no run of its own"
    assert_equal false, project["empty"], "this project has a job"
    assert_nil project["art"], "a project carries no artwork"

    job = node(body, "job:#{seed[:job].id}")
    refute_nil job
    assert_equal seed[:job].name, job["name"]
    assert_equal "B", job["tier"]
    assert_equal "done", job["state"], "the job's own state, not the candidate's"
    assert_equal job_path(seed[:job]), job["url"]
    assert_equal false, job["empty"]
    assert_nil job["art"], "and a job carries no artwork of its own"

    candidate = node(body, "candidate:#{seed[:job].id}:#{seed[:candidate].id}")
    refute_nil candidate
    assert_equal "candidate_01.svg", candidate["name"], "the candidate's own file name"
    assert_equal "C", candidate["tier"]
    assert_equal "pass", candidate["state"], "both gates cleared and the runner passed it"
    assert_equal job_path(seed[:job], candidate: "candidate_01.svg"), candidate["url"],
                 "a candidate has no page of its own: its record is the job page carrying the file"
    assert_equal file_job_path(seed[:job], name: "candidate_01.svg"), candidate["art"],
                 "the candidate's real SVG is its node art"
    assert_equal false, candidate["empty"], "this candidate was proved"

    proof = node(body, "proof:#{seed[:proof].id}")
    refute_nil proof
    assert_equal "proof_01", proof["name"],
                 "a proof is named for the candidate it proves, never by a database id"
    assert_equal "D", proof["tier"]
    assert_equal "done", proof["state"]
    assert_equal validation_path(seed[:proof]), proof["url"]
    assert_equal file_job_path(seed[:job], name: "proof_01.png"), proof["art"],
                 "the proof's render PNG is its node art"
    assert_equal false, proof["empty"]

    # The errored job: terminal with nothing traced, so it is BOTH error and empty.
    error_job = node(body, "job:#{seed[:error_job].id}")
    assert_equal "error", error_job["state"]
    assert_equal true, error_job["empty"], "a settled job that produced nothing"

    # The project that never ran.
    empty_project = node(body, "project:#{seed[:empty_project].id}")
    assert_equal true, empty_project["empty"]
  end

  test "the edges are the containment and pick lines, and every end is a real node" do
    seed = seed_graph
    sign_in
    body = graph_json
    ids = body["nodes"].map { |n| n["id"] }.to_set

    assert_equal 4, body["edges"].size,
                 "project->job, job->candidate, job->proof and candidate->proof"

    body["edges"].each do |e|
      assert ids.include?(e["from"]), "#{e['from']} is a node"
      assert ids.include?(e["to"]), "#{e['to']} is a node"
      refute_equal e["from"], e["to"], "no edge joins a node to itself"
      assert_includes %w[parent proof], e["kind"]
    end

    find_edge = ->(from, to, kind) do
      body["edges"].find { |e| e["from"] == from && e["to"] == to && e["kind"] == kind }
    end
    assert find_edge.call("project:#{seed[:project].id}", "job:#{seed[:job].id}", "parent")
    assert find_edge.call("job:#{seed[:job].id}",
                          "candidate:#{seed[:job].id}:#{seed[:candidate].id}", "parent")
    assert find_edge.call("job:#{seed[:job].id}", "proof:#{seed[:proof].id}", "proof"),
           "the pick line from the job"
    assert find_edge.call("candidate:#{seed[:job].id}:#{seed[:candidate].id}",
                          "proof:#{seed[:proof].id}", "proof"),
           "and the line from the candidate it proves"

    # The job-less errored job is a node with no project edge -- it is not dropped.
    refute_nil node(body, "job:#{seed[:error_job].id}")
  end

  test "a record's name travels as data: a name carrying a tag is not markup" do
    payload = "<img src=x onerror=alert(1)>"
    job = Job.create!(name: payload, state: "done", source_kind: "svg",
                      input_path: "/data/xss.svg", stem: "xss", runner: "mock",
                      finished_at: Time.current)
    sign_in
    body = graph_json

    served = node(body, "job:#{job.id}")["name"]
    assert_equal payload, served,
                 "the name is served VERBATIM -- escaping it here would be a second, " \
                 "different encoding from the one the record page uses"

    # The tag must not appear as an element in the document.
    refute_includes body.to_json, "<img src=x onerror=alert(1)>"
    assert_includes body.to_json, "\\u003cimg",
                 "and the JSON encoder escapes the angle brackets, so nothing downstream " \
                 "can mistake the name for markup"
  end

  test "another operator's rows stay invisible" do
    seed_graph
    sign_in
    before = graph_json

    User.create!(handle: "other", password: "other-password")
    theirs = Project.create!(name: "theirs-#{rand(1_000_000)}", is_test: false,
                             owner: "other")
    # The owner is stamped on EVERY row, not inherited from the project: a row
    # created through an association takes the CURRENT handle, which is exactly
    # the trap this test exists to avoid.
    their_job = Job.create!(name: "their-job", state: "done", source_kind: "svg",
                            input_path: "/data/t.svg", stem: "t", runner: "mock",
                            project_id: theirs.id, owner: "other")
    their_job.candidates.create!(file: "candidate_09.svg")

    after_ = graph_json
    assert_equal before["nodes"], after_["nodes"]
    assert_equal before["edges"], after_["edges"]
    refute(after_["nodes"].any? { |n| n["name"] == "their-job" },
           "another operator's job is not in this document")
  end
end
