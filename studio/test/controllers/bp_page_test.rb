require "test_helper"

# The BP page — Blend-Plot: ONE page for ONE service.
#
# This file is the merge of the old plot_page_test.rb and blender_page_test.rb,
# because the two pages merged. Every substantive assertion those two files made
# is here: both config sets on one page, each card's "?" still documenting that
# card's own fields and nothing else, the two runner maps, the two validators,
# the responsive contract facts and the transcribed constants. What changed is
# the navigation reality — one BP entry where PLOT and BLENDER used to be, and
# /plot + /blender redirecting here.
#
# The one structural thing that is NEW and therefore pinned hardest: the page
# renders the two halves as two labelled SECTIONS, and each half keeps its OWN
# FIELDS/JSON popups (with their own ids and their own content) because each half
# has its own field registry and its own generated conf.
class BpPageTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  # Runner variables read at the same moment as the registry, so they have to be
  # isolated with it -- the box running this suite has real runners configured.
  OTHER_RUNNER_ENV = %w[CHOPSHOP_FLUX_HANDOFF_RUNNER].freeze

  def doc
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    get bp_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  # The runner map is env-driven, so a suite run has to control it: this clears
  # every runner variable, applies the ones the test names, and restores the box's
  # real environment afterwards. One helper for both halves, because both are read
  # on the same render (the nav's runner pill also asks every runner for health).
  def with_runners(vars)
    saved = {}
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |key| saved[key] = ENV.delete(key) }
    OTHER_RUNNER_ENV.each { |key| saved[key] = ENV.delete(key) }
    begin
      vars.each { |key, value| ENV[key] = value }
      Job.reset_runners_cache!
      yield
    ensure
      ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |key| ENV.delete(key) }
      OTHER_RUNNER_ENV.each { |key| ENV.delete(key) }
      saved.each { |key, value| ENV[key] = value }
      Job.reset_runners_cache!
    end
  end

  def with_plot_runner(url: "http://127.0.0.1:1", kind: "plot")
    with_runners("CHOPSHOP_RUNNER_PLOT_URL" => url) do
      ENV["CHOPSHOP_RUNNER_PLOT_KIND"] = kind if kind
      Job.reset_runners_cache!
      yield
    end
  end

  def with_blender_runner(url: "http://127.0.0.1:1", kind: "blender")
    with_runners("CHOPSHOP_RUNNER_BLENDER_URL" => url) do
      ENV["CHOPSHOP_RUNNER_BLENDER_KIND"] = kind if kind
      Job.reset_runners_cache!
      yield
    end
  end

  def without_runners
    with_runners({}) { yield }
  end

  # -- the nav, and the two URLs that used to be pages ---------------------

  test "the nav carries ONE BP entry after JEV, and no PLOT or BLENDER entry" do
    links = doc.css("nav.topbar .nav-links a").map { |a| [a.text.strip, a["href"]] }
    labels = links.map(&:first)

    assert_includes labels, "BP"
    assert_operator labels.index("BP"), :>, labels.index("JEV"),
      "BP goes after JEV in the nav"
    assert_equal bp_path, links.assoc("BP").last

    # The two entries BP replaced. One service, one entry -- a page that keeps
    # both labels would be a nav that still claims two services.
    refute_includes labels, "PLOT", "PLOT is not a nav entry any more"
    refute_includes labels, "BLENDER", "BLENDER is not a nav entry any more"
    assert_equal 1, labels.count("BP"), "exactly one BP entry"

    # STATUS left the header nav for the footer's check-engine light, so it is
    # not a header link at all.
    refute_includes labels, "STATUS", "STATUS is not a header link any more"

    # The nav reads OLDEST TO NEWEST, so the LAST link is the newest page still
    # in it. BP is that page now: DATASETS has since left the row for the
    # surface that owns its subject (a FLUX popup) — the same rule that keeps
    # STATUS out of the header. So this asserts the ORDER and BP's
    # place in it, not an incumbent that changes with every page added.
    assert_operator labels.index("BP"), :>, labels.index("JEV"),
      "BP still comes after JEV"
    assert_equal "BP", labels.last,
      "and with the reference surfaces gone, BP is the newest page here"

    # The surfaces that left, named so a re-add is a deliberate act.
    refute_includes labels, "Datasets", "Datasets is a FLUX popup now"
  end

  test "the retired PLOT and BLENDER URLs redirect to the one page" do
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }

    [plot_path, blender_path].each do |old|
      get old, headers: { "User-Agent" => MODERN_UA }
      assert_response :moved_permanently,
        "#{old} is kept as a permanent redirect, so an existing link never 404s"
      assert_equal bp_path, URI.parse(response.location).path,
        "#{old} must land on the one page"

      follow_redirect!
      assert_response :success
      assert_includes response.body, 'data-bp-half="plot"'
      assert_includes response.body, 'data-bp-half="blender"'
    end
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  test "the retired URLs are still login-gated" do
    # The redirect must not become a way around the gate: require_login runs
    # BEFORE the action, so a logged-out GET lands on the login page.
    get plot_path, headers: { "User-Agent" => MODERN_UA }
    assert_redirected_to login_path
  end

  # -- the page head and the two sections -----------------------------------

  test "the page head is the house shape: Run Job top, the blurb last in the row" do
    head = doc.at_css(".page-head")
    row = head.at_css(".page-head-row")
    assert_includes row["class"].split, "page-head-row--stacked"

    title = head.at_css(".section-title")
    assert_includes title.text, "BP"
    assert_includes title.text, "Blend-Plot",
      "the subtitle spells the two halves out once; BP is the name everywhere else"

    run = head.at_css(".head-action--top")
    assert_equal "Run Job", run.text.strip

    blurb = row.at_css(".page-head-blurb")
    refute_nil blurb, "the blurb must be inside the row"
    assert_equal row.element_children.last, blurb,
      "and LAST in it, or the media query drops it below the buttons on a phone"
  end

  test "each half's label row carries that half's own reference popups" do
    # The row is per HALF, not in the page head: each half has its own field
    # registry and its own generated conf, so one head pair would point at one
    # half's popups and leave the other half's unreachable.
    {
      "plot" => [%w[FIELDS JSON], %w[plot-fields-popup plot-conf-popup]],
      "blender" => [%w[FIELDS JSON], %w[blender-fields-popup blender-conf-popup]]
    }.each do |half, (labels, popups)|
      row = doc.at_css("section[data-bp-half='#{half}'] .bp-half-head")
      refute_nil row, "the #{half} half must have a label row"
      assert_equal labels,
                   row.css(".head-action-pair .head-action").map { |b| b.text.strip },
                   "#{half}: the half's reference buttons share the label row as a pair"
      assert_equal popups,
                   row.css(".head-action-pair .head-action").map { |b| b["data-popup"] },
                   "#{half}: they open that half's own popups, in that order"
    end
  end

  test "the blurb names one service, two halves, and says the page does neither itself" do
    blurb = doc.at_css(".page-head-blurb").text.squeeze(" ").strip
    assert_includes blurb, "chopshop-bp"
    assert_match(/does neither itself/i, blurb,
      "the page configures the service: it draws nothing and renders nothing itself")
    assert_match(/draws documents/i, blurb, "the Plot half, in the operator's words")
    assert_match(/renders geometry in 3D/i, blurb, "and what the Blender half does")
  end

  test "the two halves are two labelled sections, Plot then Blender" do
    halves = doc.css("section.bp-half").map { |s| s["data-bp-half"] }
    assert_equal %w[plot blender], halves,
      "the Plot section comes first, then the Blender section"
    assert_equal %w[Plot Blender],
                 doc.css("section.bp-half .bp-half-title").map { |h| h.text.strip }

    plot = doc.at_css("section[data-bp-half='plot']")
    blender = doc.at_css("section[data-bp-half='blender']")

    # Each half holds its own cards and none of the other's -- the failure this
    # pins is a re-layout that leaves one set of cards outside its section.
    assert_equal 4, plot.css(".card[data-plot-card]").size
    assert_equal 0, plot.css(".card[data-blender-card]").size
    assert_equal 4, blender.css(".card[data-blender-card]").size
    assert_equal 0, blender.css(".card[data-plot-card]").size

    # Both halves' runner pills are on the one page: each half reports the map
    # this deployment actually files it under.
    refute_nil doc.at_css("#plotRunnerPill"), "the Plot half's runner row"
    refute_nil doc.at_css("#blenderRunnerPill"), "the Blender half's runner row"

    # Every popup survives the merge, with the ids it always had.
    %w[#plot-fields-popup #plot-conf-popup #blender-fields-popup #blender-conf-popup].each do |sel|
      refute_nil doc.at_css(sel), "#{sel} must be on the one page"
    end
  end

  # -- every card, every field, every "?" -----------------------------------

  test "every card exists with a ? that points at its own help block" do
    assert_equal %w[Service Operations Charts Geometry],
                 doc.css(".card[data-plot-card]").map { |c| c.at_css("h3").text.strip }
    assert_equal %w[Service Operation Scene Render],
                 doc.css(".card[data-blender-card]").map { |c| c.at_css("h3").text.strip }

    doc.css(".card[data-plot-card], .card[data-blender-card]").each do |card|
      title = card.at_css("h3").text.strip
      btn = card.at_css(".help-btn")
      refute_nil btn, "#{title} must have a ? button"
      target = btn["data-help-target"]
      assert doc.at_css("##{target}"), "#{title}'s ? points at ##{target}, which does not exist"
      refute_nil btn["data-help-title"]
    end
  end

  def card_labels(card)
    card.css(".field label").map { |l| l.text.strip }
  end

  def help_terms(help_id)
    doc.css("##{help_id} dt").map(&:text).map(&:strip)
  end

  test "each card's help documents all of its own fields" do
    doc.css(".card[data-plot-card], .card[data-blender-card]").each do |card|
      title = card.at_css("h3").text.strip
      terms = help_terms(card.at_css(".help-btn")["data-help-target"])
      card_labels(card).each do |label|
        assert terms.any? { |t| t.start_with?(label) },
          "#{title} is missing help for #{label.inspect} (the help documents #{terms.inspect})"
      end
    end
  end

  test "no card's help documents a field that is not its own" do
    # The pairing that matters: a card's "?" documents ITS fields and nothing
    # else. The merged page is where this could quietly break, because both
    # halves' help blocks now live in one document.
    doc.css(".card[data-plot-card], .card[data-blender-card]").each do |card|
      title = card.at_css("h3").text.strip
      labels = card_labels(card)
      help_terms(card.at_css(".help-btn")["data-help-target"]).each do |term|
        assert labels.any? { |l| term.start_with?(l) },
          "#{title}'s help documents #{term.inspect}, which is not one of its fields (#{labels.inspect})"
      end
    end
  end

  test "every environment variable is named in the help of its own half" do
    # The help blocks are siblings of the cards, not inside them, so gather them
    # by each card's own target rather than by looking for <dt> inside the card.
    { "plot" => BpConf::Plot::CARDS, "blender" => BpConf::Blender::CARDS }.each do |half, cards|
      named = doc.css("section[data-bp-half='#{half}'] .card .help-btn").flat_map do |btn|
        help_terms(btn["data-help-target"])
      end.join(" ")
      cards.each do |card|
        card[:fields].each do |f|
          next unless f[:env]
          assert_includes named, f[:env],
            "#{half}/#{card[:title]}/#{f[:label]} is #{f[:env]}, which the help does not name"
        end
      end
    end
  end

  test "the page reads no environment variable the service does not" do
    # Each half's seam is exactly five names: three service-side variables and two
    # studio-side ones, and every one of them is on the page.
    plot_envs = BpConf::Plot::CARDS.flat_map { |c| c[:fields].map { |f| f[:env] } }.compact
    assert_equal %w[CHOPSHOP_BP_BIND CHOPSHOP_BP_PORT CHOPSHOP_BP_TOKEN
                    CHOPSHOP_RUNNER_PLOT_URL CHOPSHOP_RUNNER_PLOT_KIND].sort, plot_envs.sort
    assert_includes plot_envs, BpConf::Plot::RUNNER_URL_ENV,
      "the runner URL is the whole seam and must be one of them"

    blender_envs = BpConf::Blender::CARDS.flat_map { |c| c[:fields].map { |f| f[:env] } }.compact
    assert_equal %w[CHOPSHOP_BP_BIND CHOPSHOP_BP_PORT CHOPSHOP_BP_TOKEN
                    CHOPSHOP_RUNNER_BLENDER_KIND CHOPSHOP_RUNNER_BLENDER_URL].sort,
                 blender_envs.sort
    assert_includes blender_envs, BpConf::Blender::RUNNER_URL_ENV,
      "the runner URL is the whole seam and must be one of them"
    assert_includes blender_envs, BpConf::Blender::RUNNER_KIND_ENV,
      "and the kind is what makes it a blender runner rather than a plot one"
  end

  test "each half's Service ? says which half of the one service it is" do
    # The combination, said once per half, on the one card that names the service.
    {
      "plot" => "Plot",
      "blender" => "Blender"
    }.each do |half, label|
      help_id = half == "plot" ? BpConf::Plot::CARDS.find { |c| c[:title] == "Service" }[:help]
                               : BpConf::Blender::CARDS.find { |c| c[:title] == "Service" }[:help]
      block = doc.at_css("##{help_id}")
      refute_nil block
      text = block.text.gsub(/\s+/, " ")
      assert_includes text, "chopshop-bp",
        "#{half}: the help must name the one service both halves live in"
      assert_match(/one service, two halves/i, text, "#{half}: and say it is one of them")
      assert_includes text, label, "#{half}: naming this half"
      other = half == "plot" ? "Blender" : "Plot"
      assert_includes text, other, "#{half}: and naming the other half"
    end
  end

  test "no ERB scaffolding leaked into the page as text" do
    # A fuzzy patch once closed an ERB comment a line early on FLUX, so its body
    # rendered as visible page text and nothing else noticed. Check the text.
    body = doc.text
    ["<%#", "%>", "BpConf::Plot::", "BpConf::Blender::", "card[:", "each do |", "end %>"].each do |token|
      refute_includes body, token, "#{token} is ERB scaffolding, not page text"
    end
  end

  # -- the two Service cards, and the runners this deployment files --------

  test "the Plot Service card shows the runner map the deployment actually has" do
    with_plot_runner(url: "http://127.0.0.1:1") do
      pill = doc.at_css("#plotRunnerPill")
      refute_nil pill, "the runner row must be in the Plot half's Service card"
      assert_equal "1 configured", pill.text.strip
      assert_includes doc.at_css("#plotRunnerNote").text, "http://127.0.0.1:1"
    end
  end

  test "with no plot runner configured the Plot card says so rather than lying" do
    # The default deployment has no plot runner: the settings still stand, and
    # "none configured" is a real answer rather than an error state.
    without_runners do
      assert_equal "none configured", doc.at_css("#plotRunnerPill").text.strip
      assert_includes doc.at_css("#plotRunnerNote").text, "CHOPSHOP_RUNNER_PLOT_URL"
    end
  end

  test "a runner of another kind is not reported as a plot runner" do
    with_plot_runner(url: "http://127.0.0.1:1", kind: "svg") do
      assert_equal "none configured", doc.at_css("#plotRunnerPill").text.strip,
        "the kind is what makes it a plot runner; the label alone does not"
    end
  end

  test "the Blender Service card shows the runner map the deployment actually has" do
    with_blender_runner(url: "http://127.0.0.1:1") do
      pill = doc.at_css("#blenderRunnerPill")
      refute_nil pill, "the runner row must be in the Blender half's Service card"
      assert_equal "1 configured", pill.text.strip
      assert_includes doc.at_css("#blenderRunnerNote").text, "http://127.0.0.1:1"
    end
  end

  test "with no blender runner configured the Blender card says so rather than lying" do
    without_runners do
      assert_equal "none configured", doc.at_css("#blenderRunnerPill").text.strip
      assert_includes doc.at_css("#blenderRunnerNote").text, "CHOPSHOP_RUNNER_BLENDER_URL"
    end
  end

  test "a runner of another kind is not reported as a blender runner" do
    with_blender_runner(url: "http://127.0.0.1:1", kind: "plot") do
      assert_equal "none configured", doc.at_css("#blenderRunnerPill").text.strip,
        "the kind is what makes it a blender runner; the label alone does not"
    end
  end

  # -- the Plot half's Checks card, which answers rather than configures ----

  test "the Plot Checks card is not one of the setting cards" do
    assert_equal 4, doc.css(".grid-2 .card[data-plot-card]").size,
      "only the four setting cards are in the grid"
    refute_nil doc.at_css("[data-plot-checks]"), "the Checks card is on the page"
    assert_nil doc.at_css(".grid-2 [data-plot-checks]"),
      "and it is outside the grid, or it unbalances the rows"
  end

  test "the Plot Checks card's own ? has help of its own" do
    button = doc.at_css("[data-plot-checks] .help-btn")
    refute_nil button, "the Checks card has a ? like every other card"
    block = doc.at_css("##{button["data-help-target"]}")
    refute_nil block, "#{button["data-help-target"]} exists"
    assert_equal BpConf::Plot::CHECKS[:fields].size, block.css("dt").size
    BpConf::Plot::CHECKS[:fields].each do |f|
      assert_includes block.css("dt").map(&:text).map(&:strip), f[:label]
    end
  end

  test "the Plot default combination is accepted, rendered server-side" do
    # No JavaScript: the card must already read correctly, and its default is a
    # valid query scatter over two numeric fields.
    verdict = doc.at_css("#plotCheckVerdict")
    refute_nil verdict
    assert_equal "accepted", verdict.text.strip
    assert_includes verdict["class"].split, "is-ok"
    refute_match(/would refuse/i, doc.at_css("#plotCheckDerived").text)
  end

  test "the Plot check offers numeric fields for the axes and categorical ones for colour" do
    x = doc.at_css("#f_plot_check_x")
    refute_nil x
    assert_equal BpConf::Plot::NUMERIC_FIELDS.keys, x.css("option").map { |o| o["value"] },
      "every numeric field, in the registry's own order -- and nothing else"
    color = doc.at_css("#f_plot_check_color")
    assert_equal [""] + BpConf::Plot::CATEGORICAL_FIELDS.keys, color.css("option").map { |o| o["value"] },
      "colour is categorical only, with an explicit (none)"
    chart = doc.at_css("#f_plot_check_chart")
    assert_equal BpConf::Plot::QUERY_CHARTS + BpConf::Plot::DIGEST_CHARTS,
                 chart.css("option").map { |o| o["value"] }
  end

  test "the page says the engine never picks an axis or a winner" do
    body = doc.text.gsub(/\s+/, " ")
    assert_match(/axis is always the user's choice|the axis is the user's choice/i, body)
    assert_match(/never picks|never chooses|not a winner|never a winner|never picks a winner/i, body)
  end

  # -- the Plot half's schema card, which is the foundation ----------------

  test "the schema card carries the registry verbatim" do
    card = doc.at_css("[data-plot-schema]")
    refute_nil card, "the metrics schema must be on the page, not only in the repo"
    names = card.css("dt").map { |dt| dt.text.strip }
    BpConf::Plot::NUMERIC_FIELDS.each_key { |f| assert_includes names, f, "numeric #{f}" }
    BpConf::Plot::CATEGORICAL_FIELDS.each_key { |f| assert_includes names, f, "categorical #{f}" }
    BpConf::Plot::IDENTITY_FIELDS.each { |f| assert_includes names, f, "identity #{f}" }
    assert_includes card.text, "metrics_version"
    assert_includes card.text, BpConf::Plot::METRICS_VERSION.to_s
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

  # -- the Plot FIELDS popup -----------------------------------------------

  test "the Plot FIELDS popup states each element's required fields verbatim" do
    popup = doc.at_css("#plot-fields-popup")
    refute_nil popup
    assert popup["hidden"], "the popup starts hidden"
    body = popup.text.gsub(/\s+/, " ")
    BpConf::ELEMENTS.each do |type, required|
      assert_includes body, type, "#{type} must be listed"
      required.each { |field| assert_includes body, field, "#{type} needs #{field} stated" }
    end
    assert_includes body, "rect, circle, ellipse, polygon, polyline, line, path"
  end

  test "the Plot FIELDS popup states what each chart reads" do
    body = doc.at_css("#plot-fields-popup").text.gsub(/\s+/, " ")
    assert_includes body, "labels"
    assert_includes body, "series"
    assert_includes body, "points"
    assert_includes body, "left"
    assert_includes body, "right"
    assert_includes body, "recipe_hash, source_sha256"
    assert_includes body, 'never "the winner", there is none'
  end

  # -- the Plot JSON popup and its facts script ----------------------------

  test "the Plot JSON popup opens with the conf already in it" do
    popup = doc.at_css("#plot-conf-popup")
    refute_nil popup
    assert popup["hidden"], "the popup starts hidden"
    out = popup.at_css("textarea#plotConfOutput")
    refute_nil out, "the terminal holds the generated conf"
    assert popup.at_css(".copy-ghost"), "and carries the copy button"
    assert_includes doc.at_css("section[data-bp-half='plot'] .bp-half-head").to_s,
                    'data-popup="plot-conf-popup"',
                    "and the Plot half's label row is what opens it"
  end

  test "the page passes the Plot rules to the browser instead of restating them" do
    facts = JSON.parse(doc.at_css("script#plotFacts").text)
    assert_equal BpConf::Plot::NUMERIC_FIELDS.keys, facts["numericFields"]
    assert_equal BpConf::Plot::CATEGORICAL_FIELDS.keys, facts["categoricalFields"]
    assert_equal BpConf::Plot::DIGEST_CHARTS, facts["digestCharts"]
    assert_equal BpConf::Plot::QUERY_CHARTS, facts["queryCharts"]
    assert_equal BpConf::Plot::QUERY_AXIS_CHARTS, facts["queryAxisCharts"]
    assert_equal BpConf::Plot::AXIS_OPS, facts["axisOps"]
    assert_equal BpConf::Plot::METRICS_VERSION, facts["metricsVersion"]
    assert_equal BpConf::SERVICE, facts["service"]
    assert_equal BpConf::DEFAULT_PORT, facts["defaultPort"]

    # The JS must not carry its own copy of the field registry or the chart
    # lists -- a second copy of a rule is a second thing to get wrong. TWO
    # scripts now live in one file, so the halves are addressed by index: Plot's
    # is first, the Blender half's is second (see the two halves' order above).
    view = File.read(Rails.root.join("app/views/pages/bp.html.erb"))
    scripts = view.scan(/<script>\n\(function \(\) \{.*?\}\)\(\);\n<\/script>/m)
    assert_equal 2, scripts.size, "one script per half, and neither may be dropped"
    script = scripts.first
    BpConf::Plot::NUMERIC_FIELDS.each_key do |field|
      refute_includes script, field, "the field registry belongs in the model, not in JS"
    end
    refute_includes script, "bar, line, scatter"
    refute_includes script, "scatter, pareto, diff"
  end

  # -- where the Plot half runs --------------------------------------------

  test "the Plot placement card says it can be one box or two" do
    card = doc.at_css("[data-plot-placement]")
    refute_nil card, "the deployment shapes must be on the page, not only in a README"

    shapes = card.css(".jev-derived-label").map { |l| l.text.strip }
    assert_equal BpConf::Plot::PLACEMENT[:shapes].map(&:first), shapes,
      "both shapes are shown, named the way the config names them"

    prose = card.css(".jev-note").map { |p| p.text.strip }.join(" ")
    assert_match(/on the same machine/i, prose, "one shape is one box")
    assert_match(/private network/i, prose,
      "the other crosses a network, which is what makes it a second shape")
    assert_match(/token/i, prose, "and crossing one is why it needs a credential")

    vars = card.css("dt").map { |dt| dt.text.strip }
    assert_includes vars, "CHOPSHOP_BP_BIND=#{BpConf::DEFAULT_BIND}"
    assert_includes vars, "CHOPSHOP_RUNNER_PLOT_URL=http://127.0.0.1:#{BpConf::DEFAULT_PORT}"
    assert(vars.any? { |v| v.start_with?("CHOPSHOP_BP_TOKEN") },
      "the split shape must name the token: a bind without one is an open endpoint")
    assert_nil doc.at_css(".grid-2 [data-plot-placement]"),
      "it is full width: two columns of shapes would be a footnote in half a row"
  end

  test "the Plot deployment card's ? is fed from its own entries, not a field list" do
    button = doc.at_css("[data-plot-placement] .help-btn")
    refute_nil button
    block = doc.at_css("##{button["data-help-target"]}")
    refute_nil block, "#{button["data-help-target"]} exists"
    assert_equal BpConf::Plot::PLACEMENT[:entries].size, block.css("dt").size
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

  # -- the Blender half's Checks card --------------------------------------

  test "the Blender Checks card is not one of the setting cards" do
    assert_equal 4, doc.css(".grid-2 .card[data-blender-card]").size,
      "only the four setting cards are in the grid"
    refute_nil doc.at_css("[data-blender-checks]"), "the Checks card is on the page"
    assert_nil doc.at_css(".grid-2 [data-blender-checks]"),
      "and it is outside the grid, or it unbalances the rows"
  end

  test "the Blender Checks card's own ? has help of its own" do
    button = doc.at_css("[data-blender-checks] .help-btn")
    refute_nil button
    block = doc.at_css("##{button["data-help-target"]}")
    refute_nil block, "#{button["data-help-target"]} exists"
    assert_equal BpConf::Blender::CHECKS[:fields].size, block.css("dt").size
  end

  test "the example document is accepted, rendered server-side" do
    # No JavaScript: the card must already read correctly, and its default is a
    # valid document -- an elements list with a render block.
    verdict = doc.at_css("#blenderCheckVerdict")
    refute_nil verdict
    assert_equal "accepted", verdict.text.strip
    assert_includes verdict["class"].split, "is-ok"
    refute_match(/would refuse/i, doc.at_css("#blenderCheckDerived").text)
  end

  test "the Blender check's controls are the config's own lists, not a second copy" do
    views = doc.at_css("#f_blender_check_views")
    refute_nil views
    assert_equal BpConf::Blender::VIEW_CHOICES.map(&:to_s), views.css("option").map { |o| o["value"] },
      "every view count the page offers, in the config's own order -- and nothing else"
    engine = doc.at_css("#f_blender_check_engine")
    assert_equal BpConf::Blender::ENGINES, engine.css("option").map { |o| o["value"] }
  end

  test "the page says the engine and the size are the document's to set" do
    body = doc.at_css("[data-blender-checks]").text.gsub(/\s+/, " ")
    assert_match(/engine and the size are the document's to set/i, body)
  end

  # -- the Blender responses card: what every caller branches on -----------

  test "the responses card states both success shapes and the 503 verbatim" do
    card = doc.at_css("[data-blender-shapes]")
    refute_nil card, "the two response shapes must be on the page, not only in the client"
    names = card.css(".jev-derived-label").map { |l| l.text.strip }
    assert_equal BpConf::Blender::RESPONSES.map(&:first), names,
      "one entry per shape, named the way the config names them"

    body = card.text.gsub(/\s+/, " ")
    assert_includes body, BpConf::Blender::SUCCESS_FRAME
    assert_includes body, BpConf::Blender::SUCCESS_MANIFEST
    assert_includes body, BpConf::Blender::UNAVAILABLE.to_s
    assert_includes body, "frames"
    assert_includes body, "glb"
    assert_match(/GET \/files\/<name>/, body,
      "the frames are fetched, so the route is part of the contract")
  end

  test "the responses card says a 503 is a STATE rather than a fault" do
    card = doc.at_css("[data-blender-shapes]")
    body = card.text.gsub(/\s+/, " ")
    assert_match(/not a fault/i, body)
    assert_match(/Unavailable/, body, "and names the class a caller sees")
    assert_includes card.at_css(".help-btn")["data-help-target"], "shapes"
  end

  # -- the Blender FIELDS popup --------------------------------------------

  test "the Blender FIELDS popup states each element's required fields verbatim" do
    popup = doc.at_css("#blender-fields-popup")
    refute_nil popup
    assert popup["hidden"], "the popup starts hidden"
    body = popup.text.gsub(/\s+/, " ")
    BpConf::ELEMENTS.each do |type, required|
      assert_includes body, type, "#{type} must be listed"
      required.each { |field| assert_includes body, field, "#{type} needs #{field} stated" }
    end
    assert_includes body, "rect, circle, ellipse, polygon, polyline, line, path"
  end

  test "the Blender FIELDS popup states the document's blocks and the render defaults" do
    body = doc.at_css("#blender-fields-popup").text.gsub(/\s+/, " ")
    assert_includes body, "tiling"
    assert_includes body, "extrude"
    assert_includes body, BpConf::Blender::EXTRUDE_FIELDS.join(", ")
    assert_includes body, BpConf::Blender::RENDER_FIELDS.join(", ")
    assert_includes body, BpConf::Blender::EXPORT_FIELDS.join(", ")
    assert_includes body, BpConf::Blender::DEFAULT_ENGINE
    assert_includes body, BpConf::Blender::DEFAULT_BACKGROUND
    assert_includes body, "glb"
  end

  # -- the Blender JSON popup and its facts script -------------------------

  test "the Blender JSON popup opens with the conf already in it" do
    popup = doc.at_css("#blender-conf-popup")
    refute_nil popup
    assert popup["hidden"], "the popup starts hidden"
    refute_nil popup.at_css("textarea#blenderConfOutput"), "the terminal holds the generated conf"
    assert popup.at_css(".copy-ghost"), "and carries the copy button"
    assert_includes doc.at_css("section[data-bp-half='blender'] .bp-half-head").to_s,
                    'data-popup="blender-conf-popup"',
                    "and the Blender half's label row is what opens it"
  end

  test "the page passes the Blender rules to the browser instead of restating them" do
    facts = JSON.parse(doc.at_css("script#blenderFacts").text)
    assert_equal BpConf::Blender::OP, facts["op"]
    assert_equal BpConf::Blender::ROUTE, facts["route"]
    assert_equal BpConf::ELEMENTS.keys, facts["elementTypes"]
    assert_equal BpConf::Blender::EXTRUDE_FIELDS, facts["extrudeFields"]
    assert_equal BpConf::Blender::RENDER_FIELDS, facts["renderFields"]
    assert_equal BpConf::Blender::EXPORT_FIELDS, facts["exportFields"]
    assert_equal BpConf::Blender::ENGINES, facts["engines"]
    assert_equal BpConf::Blender::VIEW_CHOICES.map(&:to_s), facts["viewChoices"].map(&:to_s)
    assert_equal BpConf::Blender::SUCCESS_FRAME, facts["successFrame"]
    assert_equal BpConf::Blender::SUCCESS_MANIFEST, facts["successManifest"]
    assert_equal BpConf::Blender::UNAVAILABLE, facts["unavailable"]
    assert_equal BpConf::Blender::DEFAULT_SIZE, facts["defaults"]["size"]
    assert_equal BpConf::Blender::DEFAULT_VIEWS, facts["defaults"]["views"]
    assert_equal BpConf::Blender::DEFAULT_ENGINE, facts["defaults"]["engine"]

    # The JS must not carry its own copy of the CONTRACT's lists -- a second copy
    # of a rule is a second thing to get wrong. The Blender half's script is the
    # SECOND of the two in the merged file (the Plot half's comes first).
    view = File.read(Rails.root.join("app/views/pages/bp.html.erb"))
    scripts = view.scan(/<script>\n\(function \(\) \{.*?\}\)\(\);\n<\/script>/m)
    assert_equal 2, scripts.size
    script = scripts.last
    refute_includes script, "rect, circle, ellipse"
    refute_includes script, "CYCLES"
    refute_includes script, "BLENDER_EEVEE_NEXT"
  end

  # -- where the Blender half runs -----------------------------------------

  test "the Blender placement card says it can be one box or two" do
    card = doc.at_css("[data-blender-placement]")
    refute_nil card, "the deployment shapes must be on the page, not only in a README"

    shapes = card.css(".jev-derived-label").map { |l| l.text.strip }
    assert_equal BpConf::Blender::PLACEMENT[:shapes].map(&:first), shapes

    prose = card.css(".jev-note").map { |p| p.text.strip }.join(" ")
    assert_match(/on the same machine/i, prose, "one shape is one box")
    assert_match(/private network/i, prose,
      "the other crosses a network, which is what makes it a second shape")
    assert_match(/token/i, prose, "and crossing one is why it needs a credential")
    assert_match(/Blender/i, prose, "and that Blender has to be installed there")

    vars = card.css("dt").map { |dt| dt.text.strip }
    assert_includes vars, "CHOPSHOP_BP_BIND=#{BpConf::DEFAULT_BIND}"
    assert_includes vars,
      "CHOPSHOP_RUNNER_BLENDER_URL=http://127.0.0.1:#{BpConf::DEFAULT_PORT}"
    assert(vars.any? { |v| v.start_with?("CHOPSHOP_BP_TOKEN") },
      "the split shape must name the token: a bind without one is an open endpoint")
    assert_nil doc.at_css(".grid-2 [data-blender-placement]"),
      "it is full width: two columns of shapes would be a footnote in half a row"
  end

  test "the page says the Blender operation is the same service as the Plot half" do
    body = doc.text.gsub(/\s+/, " ")
    assert_match(/same service/i, body)
    assert_includes body, BpConf::Blender::ROUTE
    assert_includes body, "/files/"
    assert_includes body, "/health"
  end
end

# The Plot half's validation, against the contract's own rules. This is that
# half's reason to exist: a combination the service would reject should be
# rejectable before anything is drawn -- and one it would accept should not be
# second-guessed.
class BpConfPlotValidationTest < ActiveSupport::TestCase
  def validate(**over)
    BpConf::Plot.validate(op: "query", chart: "scatter", x: "node_count_max",
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
    assert BpConf::Plot.numeric_field?("node_count_max")
    refute BpConf::Plot.numeric_field?("preset")
    assert BpConf::Plot.categorical_field?("preset")
    refute BpConf::Plot.categorical_field?("mae_art")
    assert BpConf::Plot.known_field?("source_sha256"), "identity fields are known, not axes"
    refute BpConf::Plot.categorical_field?("source_sha256")
  end

  test "the constants match the service's, because they are transcribed" do
    assert_equal "chopshop-bp", BpConf::SERVICE,
      "the repo behind both halves is chopshop-bp (was chopshop-plot)"
    assert_equal "127.0.0.1", BpConf::DEFAULT_BIND
    assert_equal 8796, BpConf::DEFAULT_PORT
    assert_equal 1, BpConf::Plot::METRICS_VERSION
    assert_equal %w[bar line scatter], BpConf::Plot::DIGEST_CHARTS
    assert_equal %w[scatter pareto diff], BpConf::Plot::QUERY_CHARTS
    assert_equal({ "width" => 800, "height" => 400 }, BpConf::Plot::DEFAULT_SIZE)
    assert_equal %w[rect circle ellipse polygon polyline line path text], BpConf::ELEMENTS.keys
    assert_equal 21, BpConf::Plot::NUMERIC_FIELDS.size
    assert_equal 6, BpConf::Plot::CATEGORICAL_FIELDS.size
    assert_equal %w[candidate_id run_stem source_sha256 recipe_hash], BpConf::Plot::IDENTITY_FIELDS
  end

  test "the element table keeps each type's required fields" do
    assert_equal %w[cx cy r], BpConf::ELEMENTS["circle"]
    assert_equal %w[x y width height], BpConf::ELEMENTS["rect"]
    assert_equal %w[points], BpConf::ELEMENTS["polygon"]
    assert_equal %w[d], BpConf::ELEMENTS["path"]
    assert_equal %w[x1 y1 x2 y2], BpConf::ELEMENTS["line"]
    assert_equal %w[x y content], BpConf::ELEMENTS["text"],
      "text is in the vocabulary: spec.py validates it and contract.md " \
      "documents it, so a missing row here is the silent drift #68 pins"
  end
end

# The Blender half's validation, against the contract's own rules. This is that
# half's reason to exist: a document the service would reject should be
# rejectable before anything is rendered -- and one it would accept should not be
# second-guessed.
class BpConfBlenderValidationTest < ActiveSupport::TestCase
  ELEMENTS = [{ "type" => "rect", "x" => 0, "y" => 0, "width" => 10, "height" => 10 }].freeze

  def validate(**over)
    BpConf::Blender.validate(elements: ELEMENTS, views: 1,
                         engine: BpConf::Blender::DEFAULT_ENGINE, **over)
  end

  test "a clean document has no problems" do
    result = validate
    assert_empty result[:problems]
    assert_includes result[:notes].join(" "), "engine and the size are the document's to set"
  end

  test "a document with no elements list is refused" do
    result = validate(elements: nil)
    assert_includes result[:problems].join(" "), "there is nothing to render"
  end

  test "elements that are not a list are refused" do
    result = validate(elements: { "type" => "rect" })
    assert_includes result[:problems].join(" "), "'elements' must be an array"
  end

  test "views must be a positive whole number" do
    assert_includes validate(views: 0)[:problems].join(" "), "at least 1"
    assert_includes validate(views: "many")[:problems].join(" "), "whole number"
    assert_empty validate(views: 4)[:problems]
  end

  test "views above one is noted as a frames manifest, not refused" do
    result = validate(views: 4)
    assert_empty result[:problems]
    assert_includes result[:notes].join(" "), "frames manifest"
    assert_includes result[:notes].join(" "), BpConf::Blender::SUCCESS_MANIFEST
  end

  test "an engine the spec does not know is refused rather than defaulted" do
    result = validate(engine: "MENTALRAY")
    assert_includes result[:problems].join(" "),
                    "'engine' must be one of workbench, eevee, got \"MENTALRAY\""
  end

  # The card used to call an empty `elements` list "legal ... an empty scene".
  # It is not: chopshop-bp raises "nothing to render -- 'elements' is empty and
  # there is no 'tiling'" (chopshop_bp/blender.py:241-243, asserted at
  # tests/test_blender.py:97) and answers 400 invalid_spec. The card was telling
  # an operator a body the service refuses is fine.
  #
  # The ONE case it is legal is with a `tiling` block, because the tiling is
  # then the geometry the scene repeats and `elements` only adds to it -- so the
  # check reads the document rather than the list alone.
  test "an empty elements list with no tiling is refused, because the service refuses it" do
    result = validate(elements: [])
    assert_includes result[:problems].join(" "), "renders nothing"
    assert_includes result[:problems].join(" "), "'tiling'",
      "the message has to name the one thing that makes it legal"
    refute_includes result[:notes].join(" "), "legal"
  end

  test "an empty elements list IS legal when the document carries a tiling" do
    result = validate(elements: [], document: { "tiling" => { "grid" => [2, 2] } })
    assert_empty result[:problems],
      "the tiling is the geometry then, so there is something to render"
    assert_includes result[:notes].join(" "), "legal HERE because the document carries a 'tiling' block"
  end

  test "the element predicate agrees with the table" do
    assert BpConf::Blender.element_type?("rect")
    assert BpConf::Blender.element_type?(:circle)
    refute BpConf::Blender.element_type?("arc")
  end
end

# The Blender half's constants, transcribed. A page that documents the contract
# is only useful if the constants on it ARE the contract's, so they are pinned
# here.
class BpConfBlenderContractTest < ActiveSupport::TestCase
  test "the operation, the route and the two response shapes" do
    assert_equal "chopshop-bp", BpConf::SERVICE,
      "the repo behind both halves is chopshop-bp (was chopshop-plot)"
    assert_equal "blender", BpConf::Blender::OP
    assert_equal "/blender", BpConf::Blender::ROUTE
    assert_equal "image/png", BpConf::Blender::SUCCESS_FRAME
    assert_equal "application/json", BpConf::Blender::SUCCESS_MANIFEST
    assert_equal 503, BpConf::Blender::UNAVAILABLE
    assert_equal "POST /blender, GET /files/<name>, GET /health", BpConf::Blender::API[:routes]
  end

  test "the document's vocabulary" do
    assert_equal %w[rect circle ellipse polygon polyline line path text], BpConf::ELEMENTS.keys
    assert_equal %w[elements], BpConf::Blender::DOC_KEYS
    assert_equal %w[grid cell origin element], BpConf::TILING_FIELDS
    assert_equal %w[depth bevel_depth bevel_resolution], BpConf::Blender::EXTRUDE_FIELDS
    assert_equal %w[size views background engine], BpConf::Blender::RENDER_FIELDS
    assert_equal %w[width height], BpConf::Blender::SIZE_FIELDS
    assert_equal %w[glb], BpConf::Blender::EXPORT_FIELDS
    assert_equal %w[workbench eevee], BpConf::Blender::ENGINES
  end

  test "the element table keeps each type's required fields" do
    assert_equal %w[cx cy r], BpConf::ELEMENTS["circle"]
    assert_equal %w[x y width height], BpConf::ELEMENTS["rect"]
    assert_equal %w[points], BpConf::ELEMENTS["polygon"]
    assert_equal %w[d], BpConf::ELEMENTS["path"]
    assert_equal %w[x1 y1 x2 y2], BpConf::ELEMENTS["line"]
    assert_equal %w[x y content], BpConf::ELEMENTS["text"],
      "text is in the vocabulary: spec.py validates it and contract.md " \
      "documents it, so a missing row here is the silent drift #68 pins"
  end

  test "the runner this operation is filed under, and its env names" do
    assert_equal "blender", BpConf::Blender::RUNNER_LABEL
    assert_equal "CHOPSHOP_RUNNER_BLENDER_URL", BpConf::Blender::RUNNER_URL_ENV
    assert_equal "CHOPSHOP_RUNNER_BLENDER_KIND", BpConf::Blender::RUNNER_KIND_ENV
    assert_includes Job::RUNNER_KINDS, BpConf::Blender::RUNNER_LABEL
    assert_includes Job::JOB_KINDS, BpConf::Blender::RUNNER_LABEL,
      "and it is a Run Job target, or the page would document a runner no job may use"

    # The label the page documents IS a kind the studio honours: a runner with
    # the documented variables set is what Job.runner_kind reports, what
    # Job.blender_runners selects, and a job target -- and never a pipeline
    # runner, because a renderer is not a hand-off.
    saved = {}
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |key| saved[key] = ENV.delete(key) }
    begin
      ENV["CHOPSHOP_RUNNER_BLENDER_URL"] = "http://127.0.0.1:1"
      ENV["CHOPSHOP_RUNNER_BLENDER_KIND"] = BpConf::Blender::RUNNER_LABEL
      Job.reset_runners_cache!
      assert_equal BpConf::Blender::RUNNER_LABEL, Job.runner_kind(BpConf::Blender::RUNNER_LABEL)
      assert Job.blender_runner?(BpConf::Blender::RUNNER_LABEL)
      assert_includes Job.blender_runners, BpConf::Blender::RUNNER_LABEL
      assert_includes Job.job_runners, BpConf::Blender::RUNNER_LABEL
      refute_includes Job.pipeline_runners, BpConf::Blender::RUNNER_LABEL
    ensure
      ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |key| ENV.delete(key) }
      saved.each { |key, value| ENV[key] = value }
      Job.reset_runners_cache!
    end
  end

  test "the defaults are the ones the studio composes for an omitted block" do
    assert_equal({ "width" => 1024, "height" => 1024 }, BpConf::Blender::DEFAULT_SIZE)
    assert_equal 1, BpConf::Blender::DEFAULT_VIEWS
    assert_equal "workbench", BpConf::Blender::DEFAULT_ENGINE
    assert_equal "#1a1a24", BpConf::Blender::DEFAULT_BACKGROUND
    assert_equal false, BpConf::Blender::DEFAULT_GLB
    assert_equal({ "depth" => 0.5, "bevel_depth" => 0.02, "bevel_resolution" => 2 },
                 BpConf::Blender::EXTRUDE_DEFAULTS)
  end

  test "the responses table names both shapes and the 503" do
    names = BpConf::Blender::RESPONSES.map(&:first)
    assert_equal ["one view, no GLB", "several views, or an export", "Blender absent", "an invalid spec"], names
  end
end

# The two halves are ONE service, and the merge is the record of it: one
# module, BpConf, with the service-wide constants and the shared element
# table at its own level and the two halves as namespaces inside it. The
# tag is greppable on purpose: it is how a future reader (or agent) finds
# both halves from the one module.
class BlendPlotServiceTest < ActiveSupport::TestCase
  test "the one conf file carries the greppable blend-plot connection tag" do
    file = Rails.root.join("app/models", "bp_conf.rb")
    src = file.read
    tag = src.lines.find { |line| line.start_with?("# blend-plot:") }
    refute_nil tag, "#{file} must carry the `blend-plot:` connection tag"
    assert_includes tag, "BpConf", "the tag names the module both halves live in"
    assert_includes tag, "chopshop-bp", "and the one repo both halves live in"
    assert_match(/one service/i, tag, "and says they are one service")
  end

  test "the halves are namespaces of the one module, sharing its constants" do
    assert_equal "chopshop-bp", BpConf::SERVICE,
      "one service, so one SERVICE constant -- at BpConf's level, not " \
      "re-stated per half"
    # The dedup is pinned, not just claimed: neither half may hold a
    # second copy of the service-wide table, or the merge bought nothing.
    %w[SERVICE DEFAULT_BIND DEFAULT_PORT MAX_BODY_BYTES ELEMENTS TILING_FIELDS].each do |name|
      refute_includes BpConf::Plot.constants, name.to_sym,
        "BpConf::Plot must not re-define #{name}: it is BpConf's, shared"
      refute_includes BpConf::Blender.constants, name.to_sym,
        "BpConf::Blender must not re-define #{name}: it is BpConf's, shared"
    end
    # And the halves render the SHARED table, not a copy of it: the
    # plot half's Geometry card, the blender half's Scene card and the
    # blender half's facts all read BpConf::ELEMENTS, so a type the
    # service adds shows up on both halves at once -- which is the
    # drift the merge exists to end.
    geometry = BpConf::Plot::CARDS.find { |c| c[:title] == "Geometry" }
    elements_field = geometry[:fields].find { |f| f[:label] == "elements" }
    assert_equal BpConf::ELEMENTS.keys.join(", "), elements_field[:default],
      "the plot half's Geometry card renders the shared table"
    scene = BpConf::Blender::CARDS.find { |c| c[:title] == "Scene" }
    scene_field = scene[:fields].find { |f| f[:label] == "elements" }
    assert_equal BpConf::ELEMENTS.keys.join(", "), scene_field[:default],
      "and so does the blender half's Scene card"
    assert_equal BpConf::ELEMENTS.keys, BpConf::Blender.facts["elementTypes"],
      "and the blender half's facts carry the same keys"
  end
end

# Who does which job. Three repos, three distinct jobs, and the copy has to say
# which is which -- the operator answered the ownership question directly:
#
#   chopshop-svg     COMPUTES the ML (ranker, bandit, triage gates), source of truth
#   chopshop-studio  OWNS THE METRICS ENGINE (the configuration of that ML and the
#                    presentation of server statistics: the check-engine light, the
#                    STATUS page, GET /engine.json) -- it does NOT compute the ML
#   chopshop-bp      is CALLED for blend-plot work: no scoring, no telemetry, no
#                    winner. Drawing a document IS a blend-plot task.
#
# Two things this pins against, both of which were live errors in the copy:
# the retired "metrics engine" framing for the bp repo (its own README/query.py
# billed it that way; the repo is being corrected, so studio copy must not
# reintroduce it), and reading the STATUS page's drawings as a leak.
class BlendPlotOwnershipCopyTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def page(path)
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    get path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  end

  def about
    @about ||= page(about_path)
  end

  def bp
    @bp ||= page(bp_path)
  end

  test "About gives each of the three repos its own job" do
    # Re-pointed 2026-09-30: the standalone [data-about-ownership] card was
    # folded into the "Five programs, and which one owns what" card
    # (data-about-made-of) when About was consolidated -- the ownership copy
    # itself is unchanged, so every assertion below reads the card that carries
    # it now.
    card = about.at_css("[data-about-made-of]")
    refute_nil card, "the ownership card must be on About"
    body = card.text.gsub(/\s+/, " ")

    assert_includes body, "chopshop-svg"
    assert_match(/computes the machine learning|computes the ML/i, body,
      "the pipeline is where the ML is computed")
    assert_match(/learned ranker/i, body)
    assert_match(/bandit/i, body, "the bucket bandit is part of that ML")

    assert_includes body, "chopshop-studio"
    assert_match(/owns the metrics engine/i, body,
      "the studio owns the metrics engine -- said plainly, not implied")
    assert_includes body, "GET /engine.json",
      "and names the surface that shows it"
    assert_match(/does not compute the ML/i, body,
      "the studio must say it does not compute the ML rather than imply otherwise")

    assert_includes body, "chopshop-bp"
    assert_match(/calls/i, body, "bp is the service the studio CALLS")
    assert_match(/no scoring/i, body)
    assert_match(/no telemetry/i, body)
    assert_match(/never picks a winner/i, body)

    # The correction, in the same paragraph: the version sticker is a data
    # contract, and the drawing-of-documents task is the intended division.
    assert_includes body, "metrics_version: 1"
    assert_match(/data contract/i, body)
    refute_match(/leak|gap in the design|should move into Ruby/i, body,
      "drawing a document is a blend-plot task, not a leak")
  end

  test "About does not bill bp as a metrics engine" do
    # The repo's README said "a geometry source and a metrics engine" and its
    # query.py said "an engine rather than a chart script". That framing is being
    # corrected in the bp repo; studio copy must not carry it.
    body = about.text.gsub(/\s+/, " ")
    refute_match(/geometry and metrics engine/i, body)
    refute_match(/geometry source and a metrics engine/i, body)
    refute_match(/an engine rather than a chart script/i, body)
  end

  test "the BP page's Service help says which half it is and which repo does what" do
    {
      "plot" => "Plot",
      "blender" => "Blender"
    }.each do |half, label|
      help_id = half == "plot" ? "help-plot-service" : "help-blender-service"
      block = bp.at_css("##{help_id}")
      refute_nil block, "#{half}: the Service card's help must exist"
      text = block.text.gsub(/\s+/, " ")
      assert_includes text, "one service, two halves", "#{half}: the combination, said once"
      assert_includes text, label
      assert_match(/no scoring/i, text, "#{half}: bp applies no scoring")
      assert_match(/no telemetry/i, text, "#{half}: and keeps no telemetry")
      assert_includes text, "chopshop-svg", "#{half}: the pipeline computes the ML"
      assert_match(/metrics engine/i, text, "#{half}: the studio owns it")
    end
  end

  test "the schema card's help calls metrics_version a data contract, not a scorer" do
    help_id = bp.at_css("[data-plot-schema] .help-btn")["data-help-target"]
    text = bp.at_css("##{help_id}").text.gsub(/\s+/, " ")
    assert_includes text, "metrics_version: 1"
    assert_match(/data contract/i, text)
    assert_match(/not a scoring engine/i, text)
  end

  test "the served copy names the service by its current name" do
    # The repo was renamed; copy that still calls it chopshop-plot sends the
    # operator looking for something that no longer exists. NOTE the scope: the
    # BpConf::Plot/BpConf::Blender constants are TRANSCRIPTIONS of the service's own
    # config and stay verbatim (an operator instruction), so this asserts on the
    # copy this change authored -- the page chrome, the clauses added to the two
    # Service helps, About, and the STATUS page's blurb and runner pill.
    blurb = bp.at_css(".page-head-blurb").text.squeeze(" ")
    assert_includes blurb, "chopshop-bp"
    refute_includes blurb, "chopshop-plot"

    bp.css("section.bp-half .bp-half-head").each do |row|
      refute_includes row.text, "chopshop-plot",
        "the half's own label row is our copy, not a transcription"
    end

    # The one clause each half's Service help adds is the LAST note in the block:
    # everything before it is rendered from the conf's constants.
    %w[help-plot-service help-blender-service].each do |id|
      block = bp.at_css("##{id}")
      note = block.css("p.jev-note").last.text.squeeze(" ")
      assert_includes note, "chopshop-bp", "#{id}: the added clause names the service"
      refute_includes note, "chopshop-plot", "#{id}: and never the retired name"
    end

    status = page(status_path)
    refute_includes status.at_css(".page-head-blurb").text, "chopshop-plot"
    refute_includes status.at_css("#statusRunnerPill").text, "chopshop-plot"

    about_body = about.text.gsub(/\s+/, " ")
    about_body.scan(/.{0,4}chopshop-plot.{0,20}/i).each do |mention|
      assert_match(/chopshop-plot → chopshop-bp/, mention,
        "About's only mention of the old name is the rename arrow, got #{mention.inspect}")
    end
  end

  test "no help block on BP names the retired repo" do
    # Closes a gap the test above leaves open BY DESIGN. That one is scoped to the
    # copy the rename authored, on the grounds that the BpConf::Plot/BpConf::Blender tables
    # are transcriptions of the service's own constants. That is true of the
    # CONSTANTS -- the routes, the engine names, the numbers -- and false of a help
    # SENTENCE: "chopshop-plot maps them to Blender's internal identifiers" exists
    # nowhere but the studio, so it is our copy that merely lives in the conf, and a
    # stale repo name there is ours to fix.
    #
    # Four such sentences survived the merge -- both 3D engine helps, the
    # runner-kind help, and the 3D half's "the same service as PLOT", a label
    # pointing at a nav entry that no longer exists -- and nothing was checking
    # them: the chrome assertions look at the page furniture, and the conf's own
    # test asserts on constants. So assert over the whole rendered page, which is
    # the only scope that cannot miss a help block.
    refute_includes bp.text, "chopshop-plot",
      "a rendered help block, hint or card still names the retired repo"

    refute_includes bp.text, "the same service as PLOT",
      "PLOT is not a surface any more: that label belongs to the plot half"
  end

end

# The two defects the /bp audit found, pinned as regressions.
#
# Both were the same failure in different clothes: the page told an operator
# something the SERVICE would refuse to do. A page that documents a contract has
# to be right about the contract, or it is worse than no page -- the operator
# trusts it and files a 400.
class BpPageServiceAgreementTest < ActiveSupport::TestCase
  def view
    File.read(Rails.root.join("app/views/pages/bp.html.erb"))
  end

  # The service reads CHOPSHOP_BP_TOKEN and no other token name
  # (chopshop_bp/config.py:70-77 -- there is no CHOPSHOP_BLENDER_TOKEN
  # anywhere in chopshop-bp). The generated Blender conf used to emit the
  # second name, so a token-protected deployment got a 401 on every render --
  # and the studio's own client says so in app/lib/blender_client.rb:54-58.
  test "the generated Blender conf names the token the service actually reads" do
    refute_includes view, "CHOPSHOP_BLENDER_TOKEN:",
      "the name must not be emitted; the service has never heard of it"
    assert_includes view, "CHOPSHOP_BP_TOKEN:",
      "one service, one token -- the Blender half shares the Plot half's"
  end

  # The empty-elements rule is asserted twice above (the Ruby validator and its
  # JS twin). This is the third assertion, and it is the one that fails if
  # somebody fixes one twin and not the other: the two MUST agree, because a
  # card that says "legal" in the server-rendered copy and "refused" after the
  # script runs is a card that lies twice.
  test "the JS twin and the Ruby validator agree on an empty elements list" do
    refute_includes view, "renders an empty scene: legal",
      "the old wording called a 400 legal; neither twin may say it"
    assert_includes view, "'tiling'",
      "the rule is about the tiling, and the browser copy has to carry it too"
    assert_includes BpConf::Blender.validate(elements: [])[:problems].join(" "), "'tiling'"
  end

  # The empty-elements check must read the DOCUMENT, not the list. A validator
  # that only ever saw `elements` could not tell the two cases apart, and would
  # either refuse the legal one or pass the illegal one -- both are wrong.
  test "the empty-elements rule can see a tiling, which is what decides it" do
    assert_includes view, "d.tiling",
      "the browser check reads the document for its tiling block"
    legal = BpConf::Blender.validate(elements: [], document: { "tiling" => { "grid" => [2, 2] } })
    assert_empty legal[:problems]
  end
end

# The JOB SPEC EXAMPLES section -- the gap the /bp audit found.
#
# Before it, the page documented the service thoroughly and carried a document
# example for exactly ONE operation (the blender Checks textarea). Everything an
# operator actually submits was absent, and the two JSON popups emit a *conf*,
# which Run Job refuses. So these assertions are about the section existing and
# being honest, not about styling.
class BpExamplesSectionTest < ActionDispatch::IntegrationTest
  def bp_page
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" },
         headers: { "User-Agent" => "Mozilla/5.0 (X11; Linux x86_64) Chrome/149.0.0.0" }
    get bp_path, headers: { "User-Agent" => "Mozilla/5.0 (X11; Linux x86_64) Chrome/149.0.0.0" }
    assert_response :success
    Nokogiri::HTML(response.body)
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  OPS = %w[generate digest query tree log blender].freeze

  test "every one of the six operations has a copy-pasteable spec on the page" do
    d = bp_page
    section = d.at_css("section.bp-examples")
    refute_nil section, "the page needs somewhere to show what you actually submit"

    OPS.each do |op|
      card = section.at_css(".bp-example[data-bp-example-op='#{op}']")
      refute_nil card, "#{op}: no example card"

      # The spec is carried in a JSON script block, so the copy button and the
      # shown text cannot be two different things.
      block = card.at_css("script[data-bp-example-json='#{op}']")
      refute_nil block, "#{op}: the spec has to be in the page as JSON to be copyable"
      spec = JSON.parse(block.text)
      assert_equal op, spec["op"], "#{op}: the op in the spec must be the card's op"
      assert_kind_of Hash, spec["doc"], "#{op}: a bp spec carries its document under doc"
      assert card.at_css("[data-bp-example-copy='#{op}']"), "#{op}: no copy control"
    end
  end

  test "both halves are represented, and the halves are named per card" do
    d = bp_page
    section = d.at_css("section.bp-examples")
    halves = section.css(".bp-example").map { |c| c["data-bp-example-half"] }.uniq
    assert_includes halves, "plot", "the plot half's five operations"
    assert_includes halves, "blender", "and the blender half's one"

    blender = section.at_css(".bp-example[data-bp-example-op='blender']")
    assert_equal "blender", blender["data-bp-example-half"]
  end

  test "the trace example is there for contrast, and says the wrapper rule" do
    # The one thing an operator arriving from a bp spec gets wrong: an svg job's
    # spec IS the top level, with no {"bp": …} wrapper.
    d = bp_page
    card = d.at_css(".bp-example[data-bp-example-op='trace']")
    refute_nil card, "the contrast case belongs on the page that documents bp jobs"
    spec = JSON.parse(card.at_css("script[data-bp-example-json='trace']").text)
    refute spec.key?("bp"), "an svg job has no wrapper block"
    assert spec.key?("print_method"), "its spec is the pipeline contract at the top level"
    assert_includes card.text, "no wrapper block"
  end

  test "query says the one thing that bites: runs is required and must not be empty" do
    card = bp_page.at_css(".bp-example[data-bp-example-op='query']")
    assert_includes card.text, "runs"
    assert_includes card.text, "refused",
      "an empty runs is refused, and the card has to say so rather than let " \
      "someone paste the elision and find out from a 400"
  end

  test "every bp example names the service file it came from" do
    # Provenance is the point: an example whose source can be named is one
    # somebody can re-verify when the service changes.
    section = bp_page.at_css("section.bp-examples")
    section.css(".bp-example").each do |card|
      source = card.at_css(".bp-example-source")
      refute_nil source, "#{card['data-bp-example-op']}: no provenance"
      next if card["data-bp-example-half"] == "pipeline"

      assert_includes source.text, "chopshop-bp",
        "#{card['data-bp-example-op']}: the provenance must point at the service repo"
    end
  end

  test "the trace example says where IT came from, which is not the service" do
    # The svg contract is the studio's own, documented in docs/agent-api.md --
    # chopshop-bp has nothing to do with it. Claiming otherwise would send a
    # reader to a repo that does not describe it.
    card = bp_page.at_css(".bp-example[data-bp-example-op='trace']")
    assert_equal "pipeline", card["data-bp-example-half"]
    assert_includes card.at_css(".bp-example-source").text, "agent-api"
    refute_includes card.at_css(".bp-example-source").text, "chopshop-bp"
  end

  test "the copy handler is delegated once and reads the page's own JSON" do
    view = File.read(Rails.root.join("app/views/pages/bp.html.erb"))
    assert_includes view, "window.__csBpExamples",
      "one delegated handler, not a per-button binding"
    assert_includes view, "script[data-bp-example-json=",
      "the spec is read from the rendered page, so the copy cannot disagree " \
      "with what the operator is looking at"
    # A second copy of any spec in a JS constant is the drift the jobs-index
    # partials exist to prevent.
    refute_includes view, "var BP_EXAMPLES",
      "the specs live in the model and the page, never in a JS constant too"
  end
end
