require "test_helper"

# The Prep — expanded card: the three raster-side benches that front_pipeline.sh
# does not run (filters before the tracer, the tune sweep, node_reduce after it),
# and the spec block the builder emits for them.
#
# The stage is OPT-IN. A job that does not switch it on must not pay for it, so
# the builder omits each block unless its control is on, and the test that
# matters most here is that nothing is emitted by default.
class PrepExpandCardTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def doc
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    get json_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  def view
    File.read(Rails.root.join("app/views/pages/schema.html.erb"))
  end

  def card(d, name)
    d.css(".card").find { |c| c.at_css("h3")&.text&.strip == name }
  end

  test "the benches live in the Prep card, documented by help-prep" do
    d = doc
    c = card(d, "Prep")
    refute_nil c, "the benches need a home card"
    %w[f_pe_filters f_pe_tune f_pe_nr].each do |id|
      refute_nil c.at_css("##{id}"), "#{id} must be in the Prep card"
    end

    btn = c.at_css(".help-btn")
    refute_nil btn
    assert_equal "help-prep", btn["data-help-target"]
    terms = d.at_css("#help-prep").css("dt").map(&:text).map(&:strip)
    %w[filters tune node_reduce max_nodes verify].each do |t|
      assert terms.any? { |e| e.start_with?(t) },
        "help-prep must document the bench field #{t.inspect}"
    end
  end

  test "the Prep card's only selects are still the two invert controls" do
    # The benches folded into the Prep card, but they are checkboxes/text/number
    # -- the two invert selects remain the card's only <select>s.
    prep = card(doc, "Prep")
    assert_equal %w[f_invert f_invert_mode], prep.css("select").map { |s| s["id"] }
    refute_includes prep["class"].to_s, "prep-expand"
  end

  test "every bench has an enable and the keys the pipeline reads" do
    c = card(doc, "Prep")
    # The three sub-blocks of spec.print.prep_expand.
    %w[f_pe_filters f_pe_tune f_pe_nr].each do |id|
      el = c.at_css("##{id}")
      refute_nil el, "#{id} must exist"
      assert_equal "checkbox", el["type"], "#{id} is opt-in, so it is a checkbox"
      refute el["checked"], "#{id} must default to OFF -- these cost job time"
    end

    # Parameters, by the key names the script reads.
    assert_equal "text", c.at_css("#f_pe_filters_presets")["type"]
    assert_equal "text", c.at_css("#f_pe_tune_presets")["type"]
    assert_equal "number", c.at_css("#f_pe_tune_cells")["type"]
    assert_equal "number", c.at_css("#f_pe_nr_nodes")["type"]
    assert_equal "checkbox", c.at_css("#f_pe_filters_sheet")["type"]
    assert_equal "checkbox", c.at_css("#f_pe_tune_sheet")["type"]
    assert_equal "checkbox", c.at_css("#f_pe_nr_verify")["type"]
    assert c.at_css("#f_pe_nr_verify")["checked"], "verify defaults on -- it is the check that says the art survived"
  end

  test "the benches use checkboxes/text/number, never a select" do
    # The benches folded into the Prep card; each is opt-in (checkbox) or a
    # parameter (text/number). None needs a select.
    c = card(doc, "Prep")
    %w[f_pe_filters f_pe_tune f_pe_nr f_pe_filters_sheet f_pe_tune_sheet f_pe_nr_verify].each do |id|
      assert_equal "checkbox", c.at_css("##{id}")["type"], "#{id} is opt-in, so a checkbox"
    end
    %w[f_pe_filters_presets f_pe_tune_presets].each do |id|
      assert_equal "text", c.at_css("##{id}")["type"]
    end
    %w[f_pe_tune_cells f_pe_nr_nodes].each do |id|
      assert_equal "number", c.at_css("##{id}")["type"]
    end
  end

  test "the builder emits prep_expand, per bench, only when switched on" do
    v = view
    assert_includes v, "pr.prep_expand = px;",
      "the block must be attached to spec.print"
    assert_match(/if \(\$\('f_pe_filters'\)\.checked\) \{/, v)
    assert_match(/if \(\$\('f_pe_tune'\)\.checked\) \{/, v)
    assert_match(/if \(\$\('f_pe_nr'\)\.checked\) \{/, v)

    # Nothing is emitted unless something is on: `Object.keys(px).length`.
    assert_match(/if \(Object\.keys\(px\)\.length\) pr\.prep_expand = px;/, v)

    # The wire keys are the ones prep_expand.py reads.
    %w[filters tune node_reduce].each do |key|
      assert_match(/px\.#{key} = /, v, "#{key} must be a key of the block")
    end
    assert_match(/fl\.presets = flp;/, v)
    assert_match(/tn\.max_cells = tcl;/, v)
    assert_match(/nrx\.max_nodes = nn;/, v)
    assert_match(/nrx\.verify = \$/, v)
  end

  test "max_nodes is omitted rather than defaulted a second time" do
    # Blank means "use geometry.max_nodes_per_path", which the pipeline resolves.
    # Defaulting it in the page as well would be a second source of truth for one
    # number, and the two could disagree.
    v = view
    assert_match(/var nn = num\('f_pe_nr_nodes'\); if \(nn\) nrx\.max_nodes = nn;/, v)
    assert_includes v, "Blank falls back to max_nodes_per_path in Geometry."
  end

  test "the controls are wired to rebuild the spec" do
    list = view[/document\.querySelectorAll\('(#f_invert[^']*)'\)/, 1]
    refute_nil list
    %w[f_pe_filters f_pe_filters_presets f_pe_filters_sheet f_pe_tune
       f_pe_tune_presets f_pe_tune_cells f_pe_tune_sheet f_pe_nr f_pe_nr_nodes
       f_pe_nr_verify].each do |id|
      assert_includes list, "##{id}",
        "#{id} must rebuild the spec on input, or a changed control is ignored"
    end
  end

  test "the help documents the numbers that decide the outcome" do
    t = doc.at_css("#help-prep").text
    # The stage's whole justification, and the two traps it exists to keep
    # visible: the gate clearing is not the art surviving, and a one-axis sweep
    # misleads. If these stop being said, the card is advice-free.
    assert_includes t, "candidate_NN.svg", "the reduced copy is a candidate"
    assert_includes t, "2240 to 461", "the measured erosion example"
    assert_includes t, "16px" 
    assert_includes t, "orthogonal", "layer_difference vs splice_threshold"
    assert_includes t, "19x", "the dither cost, measured"
    assert_includes t, "leaves the original alone", "originals are kept"
  end

  test "the preset box is parsed into an array, not sent as one string" do
    # trace_sweep/tune_sweep read lists; a single comma-joined string would be a
    # one-element list of unknown preset names.
    v = view
    assert_match(/function nameList\(raw\)/, v)
    assert_match(/\.filter\(function \(v\) \{ return v\.length > 0; \}\)/, v,
      "blank entries must not reach the benches as unknown presets")
  end
end
