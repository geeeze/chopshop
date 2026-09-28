require "test_helper"

# The BLENDER page: chopshop-plot's blender operation, its document vocabulary
# and its two response shapes.
#
# Three things are worth pinning here. First, the page's own rule -- each card's
# "?" documents that card's fields and nothing else -- which the JSON page
# enforces by test because its cards are hand-written. Here the cards AND the
# help both render from BlenderConf::CARDS, so the test is what catches a
# future hand-edit that breaks the pairing.
#
# Second, the CONTRACT: the route, the element vocabulary, the two success
# content types and the 503. This page is the only place an operator reads them,
# so a page that drifts from the runner is a page that lies about it.
#
# Third, the honesty rule the PLOT page carries: this page CONFIGURES a
# service and renders nothing itself.
class BlenderPageTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  # Runner variables read at the same moment as the registry, so they have to be
  # isolated with it -- the box running this suite has real runners configured.
  OTHER_RUNNER_ENV = %w[CHOPSHOP_FLUX_HANDOFF_RUNNER].freeze

  def doc
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    get blender_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  def with_blender_runner(url: "http://127.0.0.1:1", kind: "blender")
    saved = {}
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |key| saved[key] = ENV.delete(key) }
    OTHER_RUNNER_ENV.each { |key| saved[key] = ENV.delete(key) }
    begin
      ENV["CHOPSHOP_RUNNER_BLENDER_URL"] = url
      ENV["CHOPSHOP_RUNNER_BLENDER_KIND"] = kind if kind
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

  test "the page answers 200 with a session, and the nav carries BLENDER after PLOT" do
    links = doc.css("nav.topbar .nav-links a").map { |a| [a.text.strip, a["href"]] }
    labels = links.map(&:first)
    assert_includes labels, "BLENDER"
    assert_equal blender_path, links.assoc("BLENDER").last
    assert_operator labels.index("BLENDER"), :>, labels.index("PLOT"),
      "BLENDER goes after PLOT in the nav: it is that service's 3D operation"
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

  test "the blurb says this page configures and renders nothing itself" do
    blurb = doc.at_css(".page-head-blurb").text.squeeze(" ").strip
    assert_includes blurb, "chopshop-plot"
    assert_match(/renders nothing itself/i, blurb)
    assert_match(/document/i, blurb, "and names what a request actually carries")
  end

  test "every card exists with a ? that points at its own help block" do
    titles = doc.css(".card[data-blender-card]").map { |c| c.at_css("h3").text.strip }
    assert_equal %w[Service Operation Scene Render], titles

    doc.css(".card[data-blender-card]").each do |card|
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
    doc.css(".card[data-blender-card]").each do |card|
      title = card.at_css("h3").text.strip
      terms = help_terms(card.at_css(".help-btn")["data-help-target"])
      card_labels(card).each do |label|
        assert terms.any? { |t| t.start_with?(label) },
          "#{title} is missing help for #{label.inspect} (the help documents #{terms.inspect})"
      end
    end
  end

  test "no card's help documents a field that is not its own" do
    doc.css(".card[data-blender-card]").each do |card|
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
    named = doc.css(".card[data-blender-card]").flat_map do |card|
      help_terms(card.at_css(".help-btn")["data-help-target"])
    end.join(" ")
    BlenderConf::CARDS.each do |card|
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
    envs = BlenderConf::CARDS.flat_map { |c| c[:fields].map { |f| f[:env] } }.compact
    assert_equal %w[CHOPSHOP_PLOT_BIND CHOPSHOP_PLOT_PORT CHOPSHOP_PLOT_TOKEN
                    CHOPSHOP_RUNNER_BLENDER_KIND CHOPSHOP_RUNNER_BLENDER_URL].sort, envs.sort
    assert_includes envs, BlenderConf::RUNNER_URL_ENV,
      "the runner URL is the whole seam and must be one of them"
    assert_includes envs, BlenderConf::RUNNER_KIND_ENV,
      "and the kind is what makes it a blender runner rather than a plot one"
  end

  test "no ERB scaffolding leaked into the page as text" do
    # A fuzzy patch once closed an ERB comment a line early on FLUX, so its body
    # rendered as visible page text and nothing else noticed. Check the text.
    body = doc.text
    ["<%#", "%>", "BlenderConf::", "card[:", "each do |", "end %>"].each do |token|
      refute_includes body, token, "#{token} is ERB scaffolding, not page text"
    end
  end

  # -- the Service card, and the runner this deployment files --------------

  test "the Service card shows the runner map the deployment actually has" do
    with_blender_runner(url: "http://127.0.0.1:1") do
      pill = doc.at_css("#blenderRunnerPill")
      refute_nil pill, "the runner row must be in the Service card"
      assert_equal "1 configured", pill.text.strip
      assert_includes doc.at_css("#blenderRunnerNote").text, "http://127.0.0.1:1"
    end
  end

  test "with no blender runner configured the card says so rather than lying" do
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |key| ENV.delete(key) }
    Job.reset_runners_cache!
    assert_equal "none configured", doc.at_css("#blenderRunnerPill").text.strip
    assert_includes doc.at_css("#blenderRunnerNote").text, "CHOPSHOP_RUNNER_BLENDER_URL"
  end

  test "a runner of another kind is not reported as a blender runner" do
    with_blender_runner(url: "http://127.0.0.1:1", kind: "plot") do
      assert_equal "none configured", doc.at_css("#blenderRunnerPill").text.strip,
        "the kind is what makes it a blender runner; the label alone does not"
    end
  end

  # -- the Checks card, which answers rather than configures ---------------

  test "the Checks card is not one of the setting cards" do
    assert_equal 4, doc.css(".grid-2 .card[data-blender-card]").size,
      "only the four setting cards are in the grid"
    refute_nil doc.at_css("[data-blender-checks]"), "the Checks card is on the page"
    assert_nil doc.at_css(".grid-2 [data-blender-checks]"),
      "and it is outside the grid, or it unbalances the rows"
  end

  test "the Checks card's own ? has help of its own" do
    button = doc.at_css("[data-blender-checks] .help-btn")
    refute_nil button
    block = doc.at_css("##{button["data-help-target"]}")
    refute_nil block, "#{button["data-help-target"]} exists"
    assert_equal BlenderConf::CHECKS[:fields].size, block.css("dt").size
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

  test "the check's controls are the config's own lists, not a second copy" do
    views = doc.at_css("#f_blender_check_views")
    refute_nil views
    assert_equal BlenderConf::VIEW_CHOICES.map(&:to_s), views.css("option").map { |o| o["value"] },
      "every view count the page offers, in the config's own order -- and nothing else"
    engine = doc.at_css("#f_blender_check_engine")
    assert_equal BlenderConf::ENGINES, engine.css("option").map { |o| o["value"] }
  end

  test "the page says the engine and the size are the document's to set" do
    body = doc.at_css("[data-blender-checks]").text.gsub(/\s+/, " ")
    assert_match(/engine and the size are the document's to set/i, body)
  end

  # -- the Responses card: what every caller branches on -------------------

  test "the responses card states both success shapes and the 503 verbatim" do
    card = doc.at_css("[data-blender-shapes]")
    refute_nil card, "the two response shapes must be on the page, not only in the client"
    names = card.css(".jev-derived-label").map { |l| l.text.strip }
    assert_equal BlenderConf::RESPONSES.map(&:first), names,
      "one entry per shape, named the way the config names them"

    body = card.text.gsub(/\s+/, " ")
    assert_includes body, BlenderConf::SUCCESS_FRAME
    assert_includes body, BlenderConf::SUCCESS_MANIFEST
    assert_includes body, BlenderConf::UNAVAILABLE.to_s
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

  # -- the FIELDS popup -----------------------------------------------------

  test "the FIELDS popup states each element's required fields verbatim" do
    popup = doc.at_css("#blender-fields-popup")
    refute_nil popup
    assert popup["hidden"], "the popup starts hidden"
    body = popup.text.gsub(/\s+/, " ")
    BlenderConf::ELEMENTS.each do |type, required|
      assert_includes body, type, "#{type} must be listed"
      required.each { |field| assert_includes body, field, "#{type} needs #{field} stated" }
    end
    assert_includes body, "rect, circle, ellipse, polygon, polyline, line, path"
  end

  test "the FIELDS popup states the document's blocks and the render defaults" do
    body = doc.at_css("#blender-fields-popup").text.gsub(/\s+/, " ")
    assert_includes body, "tiling"
    assert_includes body, "extrude"
    assert_includes body, BlenderConf::EXTRUDE_FIELDS.join(", ")
    assert_includes body, BlenderConf::RENDER_FIELDS.join(", ")
    assert_includes body, BlenderConf::EXPORT_FIELDS.join(", ")
    assert_includes body, BlenderConf::DEFAULT_ENGINE
    assert_includes body, BlenderConf::DEFAULT_BACKGROUND
    assert_includes body, "glb"
  end

  # -- the JSON popup and the facts script ---------------------------------

  test "the JSON popup opens with the conf already in it" do
    popup = doc.at_css("#blender-conf-popup")
    refute_nil popup
    assert popup["hidden"], "the popup starts hidden"
    refute_nil popup.at_css("textarea#blenderConfOutput"), "the terminal holds the generated conf"
    assert popup.at_css(".copy-ghost"), "and carries the copy button"
    assert_includes doc.at_css(".page-head").to_s, 'data-popup="blender-conf-popup"'
  end

  test "the page passes the rules to the browser instead of restating them" do
    facts = JSON.parse(doc.at_css("script#blenderFacts").text)
    assert_equal BlenderConf::OP, facts["op"]
    assert_equal BlenderConf::ROUTE, facts["route"]
    assert_equal BlenderConf::ELEMENTS.keys, facts["elementTypes"]
    assert_equal BlenderConf::EXTRUDE_FIELDS, facts["extrudeFields"]
    assert_equal BlenderConf::RENDER_FIELDS, facts["renderFields"]
    assert_equal BlenderConf::EXPORT_FIELDS, facts["exportFields"]
    assert_equal BlenderConf::ENGINES, facts["engines"]
    assert_equal BlenderConf::VIEW_CHOICES.map(&:to_s), facts["viewChoices"].map(&:to_s)
    assert_equal BlenderConf::SUCCESS_FRAME, facts["successFrame"]
    assert_equal BlenderConf::SUCCESS_MANIFEST, facts["successManifest"]
    assert_equal BlenderConf::UNAVAILABLE, facts["unavailable"]
    assert_equal BlenderConf::DEFAULT_SIZE, facts["defaults"]["size"]
    assert_equal BlenderConf::DEFAULT_VIEWS, facts["defaults"]["views"]
    assert_equal BlenderConf::DEFAULT_ENGINE, facts["defaults"]["engine"]

    # The JS must not carry its own copy of the CONTRACT's lists -- a second copy
    # of a rule is a second thing to get wrong.
    view = File.read(Rails.root.join("app/views/pages/blender.html.erb"))
    script = view[/<script>\n\(function \(\) \{.*?\}\)\(\);\n<\/script>/m]
    refute_nil script
    refute_includes script, "rect, circle, ellipse"
    refute_includes script, "CYCLES"
    refute_includes script, "BLENDER_EEVEE_NEXT"
  end

  # -- where any of this runs ----------------------------------------------

  test "the page says where things run, and that it can be one box or two" do
    card = doc.at_css("[data-blender-placement]")
    refute_nil card, "the deployment shapes must be on the page, not only in a README"

    shapes = card.css(".jev-derived-label").map { |l| l.text.strip }
    assert_equal BlenderConf::PLACEMENT[:shapes].map(&:first), shapes

    prose = card.css(".jev-note").map { |p| p.text.strip }.join(" ")
    assert_match(/on the same machine/i, prose, "one shape is one box")
    assert_match(/private network/i, prose,
      "the other crosses a network, which is what makes it a second shape")
    assert_match(/token/i, prose, "and crossing one is why it needs a credential")
    assert_match(/Blender/i, prose, "and that Blender has to be installed there")

    vars = card.css("dt").map { |dt| dt.text.strip }
    assert_includes vars, "CHOPSHOP_PLOT_BIND=#{BlenderConf::DEFAULT_BIND}"
    assert_includes vars,
      "CHOPSHOP_RUNNER_BLENDER_URL=http://127.0.0.1:#{BlenderConf::DEFAULT_PORT}"
    assert(vars.any? { |v| v.start_with?("CHOPSHOP_PLOT_TOKEN") },
      "the split shape must name the token: a bind without one is an open endpoint")
    assert_nil doc.at_css(".grid-2 [data-blender-placement]"),
      "it is full width: two columns of shapes would be a footnote in half a row"
  end

  test "the page says the operation is the same service as PLOT" do
    body = doc.text.gsub(/\s+/, " ")
    assert_match(/same service/i, body)
    assert_includes body, BlenderConf::ROUTE
    assert_includes body, "/files/"
    assert_includes body, "/health"
  end
end

# The validation, against the contract's own rules. This is the page's reason to
# exist: a document the service would reject should be rejectable before anything
# is rendered -- and one it would accept should not be second-guessed.
class BlenderConfValidationTest < ActiveSupport::TestCase
  ELEMENTS = [{ "type" => "rect", "x" => 0, "y" => 0, "width" => 10, "height" => 10 }].freeze

  def validate(**over)
    BlenderConf.validate(elements: ELEMENTS, views: 1,
                         engine: BlenderConf::DEFAULT_ENGINE, **over)
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
    assert_includes result[:notes].join(" "), BlenderConf::SUCCESS_MANIFEST
  end

  test "an engine the spec does not know is refused rather than defaulted" do
    result = validate(engine: "MENTALRAY")
    assert_includes result[:problems].join(" "),
                    "'engine' must be one of workbench, eevee, got \"MENTALRAY\""
  end

  test "an empty elements list is legal, and noted" do
    result = validate(elements: [])
    assert_empty result[:problems]
    assert_includes result[:notes].join(" "), "renders an empty scene"
  end

  test "the element predicate agrees with the table" do
    assert BlenderConf.element_type?("rect")
    assert BlenderConf.element_type?(:circle)
    refute BlenderConf.element_type?("arc")
  end
end

# The constants, transcribed. A page that documents the contract is only useful
# if the constants on it ARE the contract's, so they are pinned here.
class BlenderConfContractTest < ActiveSupport::TestCase
  test "the operation, the route and the two response shapes" do
    assert_equal "chopshop-plot", BlenderConf::SERVICE
    assert_equal "blender", BlenderConf::OP
    assert_equal "/blender", BlenderConf::ROUTE
    assert_equal "image/png", BlenderConf::SUCCESS_FRAME
    assert_equal "application/json", BlenderConf::SUCCESS_MANIFEST
    assert_equal 503, BlenderConf::UNAVAILABLE
    assert_equal "POST /blender, GET /files/<name>, GET /health", BlenderConf::API[:routes]
  end

  test "the document's vocabulary" do
    assert_equal %w[rect circle ellipse polygon polyline line path], BlenderConf::ELEMENTS.keys
    assert_equal %w[elements], BlenderConf::DOC_KEYS
    assert_equal %w[grid cell origin element], BlenderConf::TILING_FIELDS
    assert_equal %w[depth bevel_depth bevel_resolution], BlenderConf::EXTRUDE_FIELDS
    assert_equal %w[size views background engine], BlenderConf::RENDER_FIELDS
    assert_equal %w[width height], BlenderConf::SIZE_FIELDS
    assert_equal %w[glb], BlenderConf::EXPORT_FIELDS
    assert_equal %w[workbench eevee], BlenderConf::ENGINES
  end

  test "the element table keeps each type's required fields" do
    assert_equal %w[cx cy r], BlenderConf::ELEMENTS["circle"]
    assert_equal %w[x y width height], BlenderConf::ELEMENTS["rect"]
    assert_equal %w[points], BlenderConf::ELEMENTS["polygon"]
    assert_equal %w[d], BlenderConf::ELEMENTS["path"]
    assert_equal %w[x1 y1 x2 y2], BlenderConf::ELEMENTS["line"]
  end

  test "the runner this operation is filed under, and its env names" do
    assert_equal "blender", BlenderConf::RUNNER_LABEL
    assert_equal "CHOPSHOP_RUNNER_BLENDER_URL", BlenderConf::RUNNER_URL_ENV
    assert_equal "CHOPSHOP_RUNNER_BLENDER_KIND", BlenderConf::RUNNER_KIND_ENV
    assert_includes Job::RUNNER_KINDS, BlenderConf::RUNNER_LABEL
    assert_includes Job::JOB_KINDS, BlenderConf::RUNNER_LABEL,
      "and it is a Run Job target, or the page would document a runner no job may use"

    # The label the page documents IS a kind the studio honours: a runner with
    # the documented variables set is what Job.runner_kind reports, what
    # Job.blender_runners selects, and a job target -- and never a pipeline
    # runner, because a renderer is not a hand-off.
    saved = {}
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |key| saved[key] = ENV.delete(key) }
    begin
      ENV["CHOPSHOP_RUNNER_BLENDER_URL"] = "http://127.0.0.1:1"
      ENV["CHOPSHOP_RUNNER_BLENDER_KIND"] = BlenderConf::RUNNER_LABEL
      Job.reset_runners_cache!
      assert_equal BlenderConf::RUNNER_LABEL, Job.runner_kind(BlenderConf::RUNNER_LABEL)
      assert Job.blender_runner?(BlenderConf::RUNNER_LABEL)
      assert_includes Job.blender_runners, BlenderConf::RUNNER_LABEL
      assert_includes Job.job_runners, BlenderConf::RUNNER_LABEL
      refute_includes Job.pipeline_runners, BlenderConf::RUNNER_LABEL
    ensure
      ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |key| ENV.delete(key) }
      saved.each { |key, value| ENV[key] = value }
      Job.reset_runners_cache!
    end
  end

  test "the defaults are the ones the studio composes for an omitted block" do
    assert_equal({ "width" => 1024, "height" => 1024 }, BlenderConf::DEFAULT_SIZE)
    assert_equal 1, BlenderConf::DEFAULT_VIEWS
    assert_equal "workbench", BlenderConf::DEFAULT_ENGINE
    assert_equal "#1a1a24", BlenderConf::DEFAULT_BACKGROUND
    assert_equal false, BlenderConf::DEFAULT_GLB
    assert_equal({ "depth" => 0.5, "bevel_depth" => 0.02, "bevel_resolution" => 2 },
                 BlenderConf::EXTRUDE_DEFAULTS)
  end

  test "the responses table names both shapes and the 503" do
    names = BlenderConf::RESPONSES.map(&:first)
    assert_equal ["one view, no GLB", "several views, or an export", "Blender absent", "an invalid spec"], names
  end
end
