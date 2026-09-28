require "test_helper"

# The PLOT page: chopshop-plot's serve surface, its contract and its schema.
#
# Two things are worth pinning here. First, the page's own rule -- each card's
# "?" documents that card's fields and nothing else -- which the JSON page
# enforces by test because its cards are hand-written. Here the cards AND the
# help both render from PlotConf::CARDS, so the test is what catches a future
# hand-edit that breaks the pairing.
#
# Second, and more important: the axis rule. The engine's whole contract is that
# the axis is the USER'S choice, that a categorical field on an axis is refused
# rather than approximated, and that the engine ranks and visualises without
# choosing. A page that drifts from that is a page that lies about the engine.
class PlotPageTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  # Runner variables read at the same moment as the registry, so they have to be
  # isolated with it -- the box running this suite has real runners configured.
  OTHER_RUNNER_ENV = %w[CHOPSHOP_FLUX_HANDOFF_RUNNER].freeze

  def doc
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    get plot_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  # Runner variables that are not part of this page's own config but are read on
  # the same render (the nav's runner pill asks every runner for its health).
  def with_plot_runner(url: "http://127.0.0.1:1", kind: "plot")
    saved = {}
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |key| saved[key] = ENV.delete(key) }
    OTHER_RUNNER_ENV.each { |key| saved[key] = ENV.delete(key) }
    begin
      ENV["CHOPSHOP_RUNNER_PLOT_URL"] = url
      ENV["CHOPSHOP_RUNNER_PLOT_KIND"] = kind if kind
      Job.reset_runners_cache!
      yield
    ensure
      ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |key| ENV.delete(key) }
      OTHER_RUNNER_ENV.each { |key| ENV.delete(key) }
      saved.each { |key, value| ENV[key] = value }
      Job.reset_runners_cache!
    end
  end

  # -- the page itself -----------------------------------------------------

  test "the nav carries PLOT after JEV, with BLENDER after it" do
    links = doc.css("nav.topbar .nav-links a").map { |a| [a.text.strip, a["href"]] }
    labels = links.map(&:first)
    assert_includes labels, "PLOT"
    assert_operator labels.index("PLOT"), :>, labels.index("JEV"),
      "PLOT goes after JEV in the nav"
    assert_equal plot_path, links.assoc("PLOT").last
    # BLENDER joined after PLOT -- it is the same service's 3D operation, so it
    # reads as PLOT's neighbour rather than somewhere else in the row -- and it
    # is the last link now, for the same reason PLOT was before it.
    assert_includes labels, "BLENDER"
    assert_equal labels.index("PLOT") + 1, labels.index("BLENDER"),
      "BLENDER goes directly after PLOT"
    assert_equal blender_path, links.assoc("BLENDER").last
    # STATUS used to follow PLOT here. It left the header nav for the footer's
    # check-engine light, so the newest sidecar is the last link.
    refute_includes labels, "STATUS", "STATUS is not a header link any more"
    assert_equal "BLENDER", labels.last
  end

  test "the page head is the house shape: Run Job top, a popup pair below" do
    head = doc.at_css(".page-head")
    row = head.at_css(".page-head-row")
    assert_includes row["class"].split, "page-head-row--stacked"

    run = head.at_css(".head-action--top")
    assert_equal "Run Job", run.text.strip

    pair = head.at_css(".head-action-pair")
    refute_nil pair, "FIELDS and JSON share the row-2 cell as a pair"
    assert_includes pair["class"].split, "head-action--below"
    assert_equal %w[FIELDS JSON], pair.css(".head-action").map { |b| b.text.strip }

    blurb = row.at_css(".page-head-blurb")
    refute_nil blurb, "the blurb must be inside the row"
    assert_equal row.element_children.last, blurb,
      "and LAST in it, or the media query drops it below the buttons on a phone"
  end

  test "the blurb says this page configures and draws nothing itself" do
    blurb = doc.at_css(".page-head-blurb").text.squeeze(" ").strip
    assert_includes blurb, "chopshop-plot"
    assert_match(/draws nothing itself|generates nothing itself/i, blurb)
    assert_match(/spec/i, blurb, "and names what a request actually carries")
  end

  test "every card exists with a ? that points at its own help block" do
    titles = doc.css(".card[data-plot-card]").map { |c| c.at_css("h3").text.strip }
    assert_equal %w[Service Operations Charts Geometry], titles

    doc.css(".card[data-plot-card]").each do |card|
      title = card.at_css("h3").text.strip
      btn = card.at_css(".help-btn")
      refute_nil btn, "#{title} must have a ? button"
      target = btn["data-help-target"]
      assert doc.at_css("##{target}"), "#{title}'s ? points at ##{target}, which does not exist"
      refute_nil btn["data-help-title"]
    end
  end

  # -- the help documents the card's own fields, and only those -------------

  def card_labels(card)
    card.css(".field label").map { |l| l.text.strip }
  end

  def help_terms(help_id)
    doc.css("##{help_id} dt").map(&:text).map(&:strip)
  end

  test "each card's help documents all of its own fields" do
    doc.css(".card[data-plot-card]").each do |card|
      title = card.at_css("h3").text.strip
      terms = help_terms(card.at_css(".help-btn")["data-help-target"])
      card_labels(card).each do |label|
        assert terms.any? { |t| t.start_with?(label) },
          "#{title} is missing help for #{label.inspect} (the help documents #{terms.inspect})"
      end
    end
  end

  test "no card's help documents a field that is not its own" do
    doc.css(".card[data-plot-card]").each do |card|
      title = card.at_css("h3").text.strip
      labels = card_labels(card)
      help_terms(card.at_css(".help-btn")["data-help-target"]).each do |term|
        assert labels.any? { |l| term.start_with?(l) },
          "#{title}'s help documents #{term.inspect}, which is not one of its fields (#{labels.inspect})"
      end
    end
  end

  test "every environment variable is named in the help" do
    # The help blocks are siblings of the cards, not inside them, so gather them
    # by each card's own target rather than by looking for <dt> inside the card.
    named = doc.css(".card[data-plot-card]").flat_map do |card|
      help_terms(card.at_css(".help-btn")["data-help-target"])
    end.join(" ")
    PlotConf::CARDS.each do |card|
      card[:fields].each do |f|
        next unless f[:env]
        assert_includes named, f[:env],
          "#{card[:title]}/#{f[:label]} is #{f[:env]}, which the help does not name"
      end
    end
  end

  test "the page reads no environment variable the service does not" do
    # Three service-side variables and two studio-side ones: the seam is exactly
    # five names, and every one of them is on the page.
    envs = PlotConf::CARDS.flat_map { |c| c[:fields].map { |f| f[:env] } }.compact
    assert_equal %w[CHOPSHOP_PLOT_BIND CHOPSHOP_PLOT_PORT CHOPSHOP_PLOT_TOKEN
                    CHOPSHOP_RUNNER_PLOT_URL CHOPSHOP_RUNNER_PLOT_KIND].sort, envs.sort
    assert_includes envs, PlotConf::RUNNER_URL_ENV,
      "the runner URL is the whole seam and must be one of them"
  end

  test "no ERB scaffolding leaked into the page as text" do
    # A fuzzy patch once closed an ERB comment a line early on FLUX, so its body
    # rendered as visible page text and nothing else noticed. Check the text.
    body = doc.text
    ["<%#", "%>", "PlotConf::", "card[:", "each do |", "end %>"].each do |token|
      refute_includes body, token, "#{token} is ERB scaffolding, not page text"
    end
  end

  # -- the Service card, and the runner this deployment files - -------------

  test "the Service card shows the runner map the deployment actually has" do
    with_plot_runner(url: "http://127.0.0.1:1") do
      punch = doc.at_css("#plotRunnerPill")
      refute_nil punch, "the runner row must be in the Service card"
      assert_equal "1 configured", punch.text.strip
      assert_includes doc.at_css("#plotRunnerNote").text, "http://127.0.0.1:1"
    end
  end

  test "with no plot runner configured the card says so rather than lying" do
    # The default deployment has no plot runner: the settings still stand, and
    # "none configured" is a real answer rather than an error state.
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |key| ENV.delete(key) }
    Job.reset_runners_cache!
    assert_equal "none configured", doc.at_css("#plotRunnerPill").text.strip
    assert_includes doc.at_css("#plotRunnerNote").text, "CHOPSHOP_RUNNER_PLOT_URL"
  end

  test "a runner of another kind is not reported as a plot runner" do
    with_plot_runner(url: "http://127.0.0.1:1", kind: "svg") do
      assert_equal "none configured", doc.at_css("#plotRunnerPill").text.strip,
        "the kind is what makes it a plot runner; the label alone does not"
    end
  end

  # -- the Checks card, which answers rather than configures ----------------

  test "the Checks card is not one of the setting cards" do
    assert_equal 4, doc.css(".grid-2 .card[data-plot-card]").size,
      "only the four setting cards are in the grid"
    refute_nil doc.at_css("[data-plot-checks]"), "the Checks card is on the page"
    assert_nil doc.at_css(".grid-2 [data-plot-checks]"),
      "and it is outside the grid, or it unbalances the rows"
  end

  test "the Checks card's own ? has help of its own" do
    button = doc.at_css("[data-plot-checks] .help-btn")
    refute_nil button, "the Checks card has a ? like every other card"
    block = doc.at_css("##{button["data-help-target"]}")
    refute_nil block, "#{button["data-help-target"]} exists"
    assert_equal PlotConf::CHECKS[:fields].size, block.css("dt").size
    PlotConf::CHECKS[:fields].each do |f|
      assert_includes block.css("dt").map(&:text).map(&:strip), f[:label]
    end
  end

  test "the default combination is accepted, rendered server-side" do
    # No JavaScript: the card must already read correctly, and its default is a
    # valid query scatter over two numeric fields.
    verdict = doc.at_css("#plotCheckVerdict")
    refute_nil verdict
    assert_equal "accepted", verdict.text.strip
    assert_includes verdict["class"].split, "is-ok"
    refute_match(/would refuse/i, doc.at_css("#plotCheckDerived").text)
  end

  test "the check offers numeric fields for the axes and categorical ones for colour" do
    x = doc.at_css("#f_plot_check_x")
    refute_nil x
    assert_equal PlotConf::NUMERIC_FIELDS.keys, x.css("option").map { |o| o["value"] },
      "every numeric field, in the registry's own order -- and nothing else"
    color = doc.at_css("#f_plot_check_color")
    assert_equal [""] + PlotConf::CATEGORICAL_FIELDS.keys, color.css("option").map { |o| o["value"] },
      "colour is categorical only, with an explicit (none)"
    chart = doc.at_css("#f_plot_check_chart")
    assert_equal PlotConf::QUERY_CHARTS + PlotConf::DIGEST_CHARTS,
                 chart.css("option").map { |o| o["value"] }
  end

  test "the page says the engine never picks an axis or a winner" do
    body = doc.text.gsub(/\s+/, " ")
    assert_match(/axis is always the user's choice|the axis is the user's choice/i, body)
    assert_match(/never picks|never chooses|not a winner|never a winner|never picks a winner/i, body)
  end

  # -- the schema card, which is the foundation -----------------------------

  test "the schema card carries the registry verbatim" do
    card = doc.at_css("[data-plot-schema]")
    refute_nil card, "the metrics schema must be on the page, not only in the repo"
    names = card.css("dt").map { |dt| dt.text.strip }
    PlotConf::NUMERIC_FIELDS.each_key { |f| assert_includes names, f, "numeric #{f}" }
    PlotConf::CATEGORICAL_FIELDS.each_key { |f| assert_includes names, f, "categorical #{f}" }
    PlotConf::IDENTITY_FIELDS.each { |f| assert_includes names, f, "identity #{f}" }
    assert_includes card.text, "metrics_version"
    assert_includes card.text, PlotConf::METRICS_VERSION.to_s
  end

  test "the schema card says missing data is a state, not a zero" do
    # The rule the whole engine rests on: a skipped gate renders as absent, and a
    # chart that plots 0 for it is lying.
    body = doc.at_css("[data-plot-schema]").text.gsub(/\s+/, " ")
    assert_match(/missing data is a state, not a zero/i, body)
    assert_match(/never as 0|never as `0`/i, body)
    assert_includes body, "source_sha256"
    assert_includes body, "recipe_hash"
  end

  # -- the FIELDS popup -----------------------------------------------------

  test "the FIELDS popup states each element's required fields verbatim" do
    popup = doc.at_css("#plot-fields-popup")
    refute_nil popup
    assert popup["hidden"], "the popup starts hidden"
    body = popup.text.gsub(/\s+/, " ")
    PlotConf::ELEMENTS.each do |type, required|
      assert_includes body, type, "#{type} must be listed"
      required.each { |field| assert_includes body, field, "#{type} needs #{field} stated" }
    end
    assert_includes body, "rect, circle, ellipse, polygon, polyline, line, path"
  end

  test "the FIELDS popup states what each chart reads" do
    body = doc.at_css("#plot-fields-popup").text.gsub(/\s+/, " ")
    assert_includes body, "labels"
    assert_includes body, "series"
    assert_includes body, "points"
    assert_includes body, "left"
    assert_includes body, "right"
    assert_includes body, "recipe_hash, source_sha256"
    assert_includes body, 'never "the winner", there is none'
  end

  # -- the JSON popup and the facts script ---------------------------------

  test "the JSON popup opens with the conf already in it" do
    popup = doc.at_css("#plot-conf-popup")
    refute_nil popup
    assert popup["hidden"], "the popup starts hidden"
    out = popup.at_css("textarea#plotConfOutput")
    refute_nil out, "the terminal holds the generated conf"
    assert popup.at_css(".copy-ghost"), "and carries the copy button"
    assert_includes doc.at_css(".page-head").to_s, 'data-popup="plot-conf-popup"'
  end

  test "the page passes the rules to the browser instead of restating them" do
    facts = JSON.parse(doc.at_css("script#plotFacts").text)
    assert_equal PlotConf::NUMERIC_FIELDS.keys, facts["numericFields"]
    assert_equal PlotConf::CATEGORICAL_FIELDS.keys, facts["categoricalFields"]
    assert_equal PlotConf::DIGEST_CHARTS, facts["digestCharts"]
    assert_equal PlotConf::QUERY_CHARTS, facts["queryCharts"]
    assert_equal PlotConf::QUERY_AXIS_CHARTS, facts["queryAxisCharts"]
    assert_equal PlotConf::AXIS_OPS, facts["axisOps"]
    assert_equal PlotConf::METRICS_VERSION, facts["metricsVersion"]
    assert_equal PlotConf::SERVICE, facts["service"]
    assert_equal PlotConf::DEFAULT_PORT, facts["defaultPort"]

    # The JS must not carry its own copy of the field registry or the chart
    # lists -- a second copy of a rule is a second thing to get wrong.
    view = File.read(Rails.root.join("app/views/pages/plot.html.erb"))
    script = view[/<script>\n\(function \(\) \{.*?\}\)\(\);\n<\/script>/m]
    refute_nil script
    PlotConf::NUMERIC_FIELDS.each_key do |field|
      refute_includes script, field, "the field registry belongs in the model, not in JS"
    end
    refute_includes script, "bar, line, scatter"
    refute_includes script, "scatter, pareto, diff"
  end

  # -- where any of this runs ----------------------------------------------

  test "the page says where things run, and that it can be one box or two" do
    card = doc.at_css("[data-plot-placement]")
    refute_nil card, "the deployment shapes must be on the page, not only in a README"

    shapes = card.css(".jev-derived-label").map { |l| l.text.strip }
    assert_equal PlotConf::PLACEMENT[:shapes].map(&:first), shapes,
      "both shapes are shown, named the way the config names them"

    prose = card.css(".jev-note").map { |p| p.text.strip }.join(" ")
    assert_match(/on the same machine/i, prose, "one shape is one box")
    assert_match(/private network/i, prose,
      "the other crosses a network, which is what makes it a second shape")
    assert_match(/token/i, prose, "and crossing one is why it needs a credential")

    vars = card.css("dt").map { |dt| dt.text.strip }
    assert_includes vars, "CHOPSHOP_PLOT_BIND=#{PlotConf::DEFAULT_BIND}"
    assert_includes vars, "CHOPSHOP_RUNNER_PLOT_URL=http://127.0.0.1:#{PlotConf::DEFAULT_PORT}"
    assert(vars.any? { |v| v.start_with?("CHOPSHOP_PLOT_TOKEN") },
      "the split shape must name the token: a bind without one is an open endpoint")
    assert_nil doc.at_css(".grid-2 [data-plot-placement]"),
      "it is full width: two columns of shapes would be a footnote in half a row"
  end

  test "the deployment card's ? is fed from its own entries, not a field list" do
    button = doc.at_css("[data-plot-placement] .help-btn")
    refute_nil button
    block = doc.at_css("##{button["data-help-target"]}")
    refute_nil block, "#{button["data-help-target"]} exists"
    assert_equal PlotConf::PLACEMENT[:entries].size, block.css("dt").size
  end

  test "the page says the service is a standard API other applications can call" do
    body = doc.text.gsub(/\s+/, " ")
    assert_match(/other applications|another application|any application/i, body)
    %w[/generate /digest /query /health].each do |route|
      assert_includes body, route, "#{route} must be named: it is the whole surface"
    end
  end

  test "the page states what the service answers with, in both directions" do
    # Success is one SVG document and a refusal is a JSON envelope, which is the
    # distinction every caller branches on.
    body = doc.text.gsub(/\s+/, " ")
    assert_match(/SVG document/i, body)
    assert_match(/JSON/i, body)
    assert_match(/refus/i, body)
  end
end

# The validation, against the contract's own rules. This is the page's reason to
# exist: a combination the service would reject should be rejectable before
# anything is drawn -- and one it would accept should not be second-guessed.
class PlotConfValidationTest < ActiveSupport::TestCase
  def validate(**over)
    PlotConf.validate(op: "query", chart: "scatter", x: "node_count_max",
                      y: "mae_art", color: nil, **over)
  end

  test "a clean query scatter has no problems" do
    result = validate
    assert_empty result[:problems]
    assert_includes result[:notes].join(" "), "axis is the user's choice"
  end

  test "a categorical field on an axis is refused, in the contract's words" do
    result = validate(x: "preset")
    assert_includes result[:problems].join(" "), "axis 'preset' is not a numeric metric field"
  end

  test "a missing axis is refused rather than defaulted" do
    assert_includes validate(y: "")[:problems].join(" "), "scatter: y is required"
  end

  test "colour must be categorical, and is optional" do
    assert_includes validate(color: "mae_art")[:problems].join(" "),
                    "'color' must be a categorical field"
    assert_empty validate(color: "fidelity_verdict")[:problems]
  end

  test "scatter is a chart in BOTH operations, so neither refuses it" do
    # The name means two different things per operation -- one run's points
    # versus every candidate across every run -- but it is legal in both, so
    # "not query's" and "is digest's" are different questions.
    assert_empty validate(op: "digest", chart: "scatter", x: nil, y: nil)[:problems]
    assert_empty validate(op: "query", chart: "scatter")[:problems]
  end

  test "a chart the other operation owns is refused, and only by that one" do
    assert_includes validate(op: "digest", chart: "pareto")[:problems].join(" "),
                    "pareto is a query chart: the digest operation reads one run's numbers"
    assert_includes validate(op: "query", chart: "bar")[:problems].join(" "),
                    "bar is a digest chart: the query operation reads run records"
    assert_empty validate(op: "digest", chart: "bar", x: nil, y: nil)[:problems]
  end

  test "diff takes selectors rather than axes, so the axis rule does not apply" do
    result = validate(chart: "diff", x: nil, y: nil)
    assert_empty result[:problems],
      "diff is a query chart with left/right selectors; demanding axes of it would be wrong"
  end

  test "an unknown chart is refused with the lists" do
    result = validate(chart: "pie")
    assert_includes result[:problems].join(" "), "'chart' must be one of bar, line, scatter"
    assert_includes result[:problems].join(" "), "scatter, pareto, diff"
  end

  test "generate takes a geometry spec, not a chart" do
    result = validate(op: "generate")
    assert_empty result[:problems]
    assert_includes result[:notes].join(" "), "generate takes no chart"
  end

  test "an unknown operation is refused" do
    assert_includes validate(op: "render")[:problems].join(" "),
                    "'op' must be one of generate, digest, query"
  end

  test "the field predicates agree with the registry" do
    assert PlotConf.numeric_field?("node_count_max")
    refute PlotConf.numeric_field?("preset")
    assert PlotConf.categorical_field?("preset")
    refute PlotConf.categorical_field?("mae_art")
    assert PlotConf.known_field?("source_sha256"), "identity fields are known, not axes"
    refute PlotConf.categorical_field?("source_sha256")
  end

  test "the constants match the service's, because they are transcribed" do
    assert_equal "chopshop-plot", PlotConf::SERVICE
    assert_equal "127.0.0.1", PlotConf::DEFAULT_BIND
    assert_equal 8796, PlotConf::DEFAULT_PORT
    assert_equal 1, PlotConf::METRICS_VERSION
    assert_equal %w[bar line scatter], PlotConf::DIGEST_CHARTS
    assert_equal %w[scatter pareto diff], PlotConf::QUERY_CHARTS
    assert_equal({ "width" => 800, "height" => 400 }, PlotConf::DEFAULT_SIZE)
    assert_equal %w[rect circle ellipse polygon polyline line path], PlotConf::ELEMENTS.keys
    assert_equal 21, PlotConf::NUMERIC_FIELDS.size
    assert_equal 6, PlotConf::CATEGORICAL_FIELDS.size
    assert_equal %w[candidate_id run_stem source_sha256 recipe_hash], PlotConf::IDENTITY_FIELDS
  end

  test "the element table keeps each type's required fields" do
    assert_equal %w[cx cy r], PlotConf::ELEMENTS["circle"]
    assert_equal %w[x y width height], PlotConf::ELEMENTS["rect"]
    assert_equal %w[points], PlotConf::ELEMENTS["polygon"]
    assert_equal %w[d], PlotConf::ELEMENTS["path"]
    assert_equal %w[x1 y1 x2 y2], PlotConf::ELEMENTS["line"]
  end
end
