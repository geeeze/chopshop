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
       f_pe_nr_verify f_pe_filters_alpha f_pe_filters_spec f_pe_tune_speckle
       f_pe_tune_hier f_pe_tune_nr f_pe_nr_tolerance f_pe_nr_tolerance_cap
       f_prep_opaque_bg f_prep_colors f_ramp_min_members f_pv_transforms].each do |id|
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

  # ---- the sub-keys the benches are documented to take ---------------------
  #
  # prep_expand.py honours these inside its three blocks (filters.keep_alpha,
  # filters.spec, tune.filter_speckle, tune.hierarchical, tune.with_node_reduce,
  # node_reduce.tolerance, node_reduce.tolerance_cap) and the studio exposed
  # none of them. A bench that cannot be pointed at the pass it exists to
  # compare is a bench nobody can use.

  test "every honoured sub-key has a control in the Prep card" do
    c = card(doc, "Prep")
    %w[f_pe_filters_alpha f_pe_filters_spec f_pe_tune_speckle f_pe_tune_hier
       f_pe_tune_nr f_pe_nr_tolerance f_pe_nr_tolerance_cap].each do |id|
      refute_nil c.at_css("##{id}"), "#{id} must be in the Prep card"
    end

    assert_equal "checkbox", c.at_css("#f_pe_filters_alpha")["type"]
    assert_equal "checkbox", c.at_css("#f_pe_tune_nr")["type"]
    assert_equal "text", c.at_css("#f_pe_filters_spec")["type"]
    assert_equal "text", c.at_css("#f_pe_tune_speckle")["type"]
    assert_equal "text", c.at_css("#f_pe_tune_hier")["type"]
    assert_equal "number", c.at_css("#f_pe_nr_tolerance")["type"]
    assert_equal "number", c.at_css("#f_pe_nr_tolerance_cap")["type"]

    # The two opt-in switches default OFF, like the benches they belong to.
    %w[f_pe_filters_alpha f_pe_tune_nr].each do |id|
      refute c.at_css("##{id}")["checked"], "#{id} costs job time, so it is opt-in"
    end
  end

  test "the writer emits each sub-key under the bench the script reads it in" do
    v = view
    # filters: keep_alpha (a flag) and spec (a path).
    assert_match(/if \(\$\('f_pe_filters_alpha'\)\.checked\) fl\.keep_alpha = true;/, v)
    assert_match(/var flSpec = val\('f_pe_filters_spec'\); if \(flSpec\) fl\.spec = flSpec;/, v)
    # tune: filter_speckle (numbers), hierarchical (names), with_node_reduce.
    assert_match(/var tsp = numList\(val\('f_pe_tune_speckle'\)\);/, v)
    assert_match(/if \(tsp\.length\) tn\.filter_speckle = tsp;/, v)
    assert_match(/var thr = nameList\(val\('f_pe_tune_hier'\)\);\s*\n\s*if \(thr\.length\) tn\.hierarchical = thr;/, v)
    assert_match(/if \(\$\('f_pe_tune_nr'\)\.checked\) tn\.with_node_reduce = true;/, v)
    # node_reduce: tolerance and tolerance_cap, both of which accept 0.
    assert_match(/var nrt = num\('f_pe_nr_tolerance'\); if \(nrt !== null && nrt >= 0\) nrx\.tolerance = nrt;/, v)
    assert_match(/var nrc = num\('f_pe_nr_tolerance_cap'\); if \(nrc !== null && nrc >= 0\) nrx\.tolerance_cap = nrc;/, v)
  end

  test "a sub-key that is left alone is not emitted" do
    # Same rule one level down as the blocks themselves: off/blank means the
    # tool's own default, so an operator who switches a bench on and touches
    # nothing else gets the block the bench always composed.
    v = view
    assert_match(/if \(\$\('f_pe_filters_alpha'\)\.checked\) fl\.keep_alpha = true;/, v,
      "keep_alpha is written only when ticked -- never as false")
    refute_match(/fl\.keep_alpha = \$\('f_pe_filters_alpha'\)\.checked;/, v,
      "writing the false would overrule im_filters' own default")
    refute_match(/fl\.keep_alpha = false/, v)
    refute_match(/tn\.with_node_reduce = \$\('f_pe_tune_nr'\)\.checked;/, v)
    refute_match(/fl\.spec = ''/, v)
  end

  test "filter_speckle is parsed as numbers, and a blank box stays blank" do
    # Number('') is 0, which is a real speckle value: a cleared box used to post
    # `filter_speckle: [0]` -- an axis nobody asked for.
    v = view
    assert_match(/function numList\(raw\)/, v)
    assert_match(/\.filter\(function \(v\) \{ return v\.length > 0; \}\)\s*\n\s*\.map\(function \(v\) \{ return Number\(v\); \}\)/, v,
      "blanks are dropped BEFORE the numeric coercion, not turned into 0")
  end

  # ---- the two prep-stage switches -----------------------------------------
  #
  # prep_raster.py reads print.assume_opaque_bg and print.prep_colors (the
  # documented default is 16 colours; null disables quantisation). They belong
  # with the benches because they decide what raster the benches run on.

  test "the prep-stage switches are on the Prep card and omitted when untouched" do
    c = card(doc, "Prep")
    refute_nil c.at_css("#f_prep_opaque_bg"), "assume_opaque_bg needs a control"
    refute_nil c.at_css("#f_prep_colors"), "prep_colors needs a control"
    assert_equal "checkbox", c.at_css("#f_prep_opaque_bg")["type"]
    refute c.at_css("#f_prep_opaque_bg")["checked"], "false is the documented default"
    assert_equal "text", c.at_css("#f_prep_colors")["type"],
      "prep_colors must not be a select -- the Prep card's only selects are the two invert controls"

    v = view
    assert_match(/if \(\$\('f_prep_opaque_bg'\)\.checked\) pr\.assume_opaque_bg = true;/, v)
    assert_match(/if \(pcRaw === 'null'\) \{\s*\n\s*pr\.prep_colors = null;/, v,
      "null is the documented 'no quantisation' and has to survive as null")
    assert_match(/var pcNum = Number\(pcRaw\);\s*\n\s*if \(pcNum > 0\) pr\.prep_colors = pcNum;/, v,
      "a word where the pipeline does int() would break the run, so it is not posted")
  end

  test "the help documents the sub-keys and the prep switches" do
    terms = doc.at_css("#help-prep").css("dt").map(&:text).map(&:strip)
    %w[keep_alpha spec filter_speckle hierarchical with_node_reduce tolerance
       tolerance_cap assume_opaque_bg prep_colors].each do |t|
      assert terms.any? { |e| e.start_with?(t) },
        "help-prep must document #{t.inspect}, or the card documents a control it does not explain"
    end
  end
end
