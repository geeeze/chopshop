require "test_helper"

# THE TWO OPT-IN SURFACES: the Run Job page's flux settings popup (modifiers,
# the VAE swap, and the proof-variants opt-in) and the JSON page's builder.
#
# There is a limit worth stating plainly, because it shapes every assertion here:
# Rails renders no JavaScript, so the FILTERING of the two lists and the
# COMPOSITION of the spec both happen in the browser and neither can be executed
# by this suite. What can be pinned — and is — is the contract the browser
# scripts are built on:
#
#   * the registry the server hands over (every option's `data-targets`, the
#     licence in its text), which is what the filter reads;
#   * the ids the scripts bind to, which the brief fixes as the JS's contract;
#   * the EXACT composition statements the shipped script contains, so a rewrite
#     that quietly stops writing `validation.variants` fails here even though no
#     browser ran;
#   * and that every field that must POST is still inside the <form>.
#
# Anything stronger would need a JS runtime in the suite, which this app does not
# have and does not want.
class FluxModifierFormTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def doc
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    get new_job_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  end

  # The script the browser actually receives, in one string.
  def script(doc)
    doc.css("script").map(&:text).join("\n")
  end

  def option_targets(doc, select_id)
    doc.css("##{select_id} option").map do |o|
      [o["value"], (o["data-targets"] || "").split(",").reject(&:empty?)]
    end
  end

  # --- the registry the popup hands over ----------------------------------

  test "the popup offers every modifier, each carrying the models it may load against" do
    popup = doc.at_css("#flux-settings-popup")
    refute_nil popup, "the flux settings popup must be on the page"
    refute_nil popup.at_css("#flux_modifiers"), "the modifiers control must be in it"

    offered = option_targets(doc, "flux_modifiers")
    assert_equal FluxConf::MODIFIERS.keys, offered.map(&:first),
                 "the control is the registry, in order: nothing added, nothing dropped"
    offered.each do |value, targets|
      assert_equal FluxConf::MODIFIERS[value]["targets"].sort, targets.sort,
                   "#{value} must carry its own targets, which is what the filter reads"
    end
  end

  test "a modifier targeting only the SD family is not offered to klein" do
    # The filter itself is the browser's, so what is pinned here is the fact it
    # filters ON: the option's targets exclude the default model, and the
    # registry's own helper agrees. Both halves matter — if either said
    # otherwise, the JS would either offer it or drop the wrong things.
    targets = option_targets(doc, "flux_modifiers").to_h
    refute_includes targets["pixel-art-xl"], "klein-4b"
    refute_includes targets["sdxl-lightning-4step"], "klein-4b"
    refute_includes targets["klein-outpaint"], "sdxl-1.0"

    assert_equal %w[klein-background-remove klein-object-remove klein-outpaint klein-spritesheet],
                 FluxConf.modifiers_for("klein-4b").map { |m| m["key"] }
    assert_empty(FluxConf.modifiers_for("klein-4b").map { |m| m["key"] } & %w[pixel-art-xl shelf-sdxl])

    # And the page ships the filter that does it, keyed on data-targets and the
    # chosen model rather than on a second list typed into the view.
    code = script(doc)
    assert_includes code, "ALL_MODIFIERS", "the full option list must be captured before filtering"
    assert_includes code, "data-targets"
    assert_includes code, "function rebuildOptions"
    assert_includes code, "spec.targets.indexOf(model) === -1"
    assert_includes code, "function syncRegistry"
  end

  # The Run Job page's page-level IIFE reads FACTS.constraints.defaultModel
  # inside syncRegistry(). The FACTS parse and the JSON element it reads are the
  # ONLY contract that survives a missing declaration: drop either one and the
  # IIFE throws at that line, syncRegistry() dies, and the model → modifier/VAE
  # filter never runs. Pinned on the served body, so removing either half fails.
  test "the page hands the rules to the browser as the fluxFacts JSON, and the IIFE parses it" do
    facts_el = doc.at_css("script#fluxFacts")
    refute_nil facts_el, "the Run Job page must emit the facts JSON element"
    assert_equal "application/json", facts_el["type"],
                 "it must be a JSON block, so its content is not JavaScript"

    # The exact parse statement, first thing in the page-level IIFE — the same
    # arrangement the FLUX page uses.
    code = script(doc)
    assert_includes code, "var FACTS = JSON.parse(document.getElementById('fluxFacts').textContent);"

    # And the JSON element's content must parse to an object carrying
    # constraints.defaultModel, which is the line syncRegistry() reads.
    facts = JSON.parse(facts_el.text)
    assert_kind_of Hash, facts
    refute_nil facts["constraints"], "the JSON must carry the constraints block"
    assert_equal FluxConf::DEFAULT_MODEL_KEY, facts["constraints"]["defaultModel"]
    assert_equal FluxConf::MODELS.keys, facts["models"].keys,
                 "the registry handed to the browser is the mirror's, in order"
  end

  # THE PER-MODEL RESOLUTION RULES (#62). The width/height bounds and their
  # hints used to be klein's, statically, for all eleven models — the operator's
  # "defaults don't change even when they are clearly model-specific" complaint.
  #
  # Rails renders no JavaScript, so the CLAMPING cannot be executed here. What
  # is pinned is the contract the clamp is built on, in the two halves the FLUX
  # page established: the per-model rules the server hands over (so Sana really
  # carries 512/32/1MP against klein's 64/16/4MP, and the facts mirror
  # FluxConf.limits), and the EXACT statements the shipped script contains — so
  # reverting the view to a static hint fails here even though no browser ran.
  test "the width and height bounds and hints follow the SELECTED model, read from the facts" do
    facts_el = doc.at_css("script#fluxFacts")
    refute_nil facts_el, "the Run Job page must emit the facts JSON element"
    facts = JSON.parse(facts_el.text)

    # HALF ONE — the facts carry each model's OWN three rules, and they agree
    # with the registry reader. The drift test pins FluxConf.limits itself;
    # this pins that what the BROWSER is handed is that same reading.
    FluxConf::MODELS.each do |key, spec|
      served = facts["models"][key]
      refute_nil served, "#{key} must be in the handed-over registry"
      limits = FluxConf.limits(key)
      %w[min_dim dim_multiple max_pixels].each do |field|
        assert_equal limits[field], served[field],
                     "#{key}.#{field}: the browser must see the model's own rule, " \
                     "which is what FluxConf.limits returns"
      end
    end

    # And they are NOT all klein's: Sana differs on all three, which is the
    # whole point. If this assertion fails, the per-model fix has reverted.
    sana = facts["models"]["sana-sprint-0.6b"]
    klein = facts["models"]["klein-4b"]
    assert_equal [512, 32, 1024 * 1024], [sana["min_dim"], sana["dim_multiple"], sana["max_pixels"]],
                 "Sana's own rules: 512 min, multiples of 32, 1 MP cap"
    assert_equal [64, 16, 4 * 1024 * 1024], [klein["min_dim"], klein["dim_multiple"], klein["max_pixels"]],
                 "klein's rules stay klein's"
    refute_equal klein.slice("min_dim", "dim_multiple", "max_pixels"),
                 sana.slice("min_dim", "dim_multiple", "max_pixels"),
                 "the two families must not share one rule set"

    # The fallback block is still there, for an entry that carries none.
    %w[minDimension dimensionMultiple maxPixels].each do |field|
      refute_nil facts["constraints"][field], "constraints.#{field} is the fallback"
    end

    # HALF TWO — the shipped script reads the per-model fields, not a second
    # list re-typed in the view. The read statements are what makes the facts
    # above mean anything in the browser: drop either and the form is back to
    # describing klein whatever model is selected.
    code = script(doc)
    assert_includes code, "spec.min_dim || FACTS.constraints.minDimension",
                     "the min must come from the model's own min_dim, klein's only as fallback"
    assert_includes code, "spec.dim_multiple || FACTS.constraints.dimensionMultiple",
                     "the step must come from the model's own dim_multiple"
    assert_includes code, "spec.max_pixels || FACTS.constraints.maxPixels",
                     "the pixel cap must come from the model's own max_pixels"
    assert_includes code, "input.min = String(limits.minDimension);",
                     "the width/height boxes must carry the selected model's floor"
    assert_includes code, "input.step = String(limits.dimensionMultiple);",
                     "and its step"
    # The hints carry the model's own numbers, and both hint elements are the
    # ones this updates — the ids the function reaches for.
    assert_includes code, "document.getElementById('fluxWidthHint')",
                     "the width hint must be reachable by id so its text can follow the model"
    assert_includes code, "document.getElementById('fluxHeightHint')",
                     "the height hint likewise"
    # And the sync runs on the model change and on init, through the ONE gate
    # function — not a second change listener of its own.
    assert_includes code, "syncDimensionRules();",
                     "updateModelGates must call syncDimensionRules so load and change both run it"

    # The served markup still carries the two hint ids, so a rename in the view
    # without a rename in the script fails here.
    refute_nil doc.at_css("#fluxWidthHint"), "the width hint element must be on the page"
    refute_nil doc.at_css("#fluxHeightHint"), "the height hint element must be on the page"
  end

  # The recursion the review caught (issue #62), which every assertion above is
  # blind to because Rails renders no JavaScript: syncDimensionRules runs inside
  # updateModelGates, which runs inside writePanels, so refreshing the panels
  # FROM INSIDE syncDimensionRules recurses to a stack overflow. Pin the SHAPE —
  # the function must not call writePanels, and the model-change listener must
  # route through writePanels (so the composed spec still refreshes on a change).
  test "syncDimensionRules must not call writePanels, and the model change refreshes through it" do
    code = script(doc)
    body = code[/function syncDimensionRules\(\)\s*\{(.*?)^  \}/m, 1]
    refute_nil body, "syncDimensionRules must be present in the shipped script"
    refute_match(/writePanels\s*\(/, body,
                 "syncDimensionRules must NOT call writePanels(): writePanels() -> " \
                 "updateModelGates() -> syncDimensionRules() recurses to a stack overflow. " \
                 "The refresh belongs at the call site, not inside the function.")
    assert_match(/if \(fluxModelSel\) fluxModelSel\.addEventListener\('change', writePanels\)/,
                 code,
                 "a model change must go through writePanels so the composed spec refreshes")
  end

  test "the vae control is the VAE registry, and every option shows its licence" do
    select = doc.at_css("#flux_vae")
    refute_nil select

    values = select.css("option").map { |o| o["value"] }
    assert_equal [""] + FluxConf::VAES.keys, values,
                 "a blank first option means the model's own decoder, then the swaps"

    FluxConf::VAES.each_value do |spec|
      option = select.at_css("option[value='#{spec['key']}']")
      refute_nil option, "#{spec['key']} must be offered"
      assert_includes option.text, spec["licence"],
                      "#{spec['key']}'s licence must be visible on the option, not implied"
      assert_equal spec["targets"].sort,
                   option["data-targets"].split(",").reject(&:empty?).sort
      assert_includes option["title"].to_s, spec["repo_id"],
                      "the tooltip names the repo the file comes from"
    end

    # Same for a modifier, which carries its own licence by design.
    mod = doc.at_css("#flux_modifiers option[value='lcm-lora-sd15']")
    assert_includes mod.text, "CreativeML Open RAIL-M License",
                    "a LoRA's licence is its own; bolting it on does not launder it"
    assert_includes mod["title"].to_s, "latent-consistency/lcm-lora-sdv1-5"
  end

  test "a model with no modifiers gets an empty control AND the reason it is empty" do
    # No LoRA targets the Sana family, so the control must be empty and say so
    # rather than present a list that cannot be used.
    assert_empty FluxConf.modifiers_for("sana-sprint-0.6b")

    empty = doc.at_css("#fluxModifiersEmpty")
    refute_nil empty, "the empty state must exist, or the control is silently inert"
    assert empty.key?("hidden"), "and start hidden, because klein DOES have adapters"
    assert_match(/no lora is registered/i, empty.text)
    assert_match(/nothing to stack/i, empty.text)

    code = script(doc)
    assert_includes code, "modifiersEmpty.hidden = available !== 0",
                    "the script must swap the list for the reason when the list is empty"
  end

  # --- the opt-in -----------------------------------------------------------

  test "the proof-variants opt-in is inside the form, behind its own help, and offered for the proof-producing kinds" do
    block = doc.at_css("#proofVariantsBlock")
    refute_nil block, "the opt-in must be on the page"
    assert_equal %w[svg flux], block["data-proof-fields"].split(/\s+/),
                 "it applies to the two kinds that produce a proof, and to no others"
    refute_nil block.at_css("#proof_variants"), "the control is a real checkbox"

    # The site-wide "?" arrangement: a .help-btn pointing at a hidden notes block.
    btn = block.at_css(".help-btn")
    refute_nil btn, "the opt-in carries a ? like every other documented control"
    assert_equal "help-proof-variants", btn["data-help-target"]
    refute_nil doc.at_css("#help-proof-variants"), "and the notes block it points at exists"

    notes = doc.at_css("#help-proof-variants").text
    assert_match(/train/i, notes)
    assert_match(/proof/i, notes)
    assert_match(/raster-only/i, notes, "it must say a raster-only run has nothing to vary")

    hint = block.at_css(".hint").text.gsub(/\s+/, " ")
    assert_match(/flipped/i, hint, "the hint must say what the copies are")
    assert_match(/PROOF/, hint, "and that they are copies of the PROOF")
    assert_match(/raster-only flux job has no proof to vary/, hint)
  end

  test "the fields that must POST are still descendants of the <form> node" do
    # The JOB form specifically: the topbar carries a logout `button_to`, which
    # is the first <form> in the document and posts nothing of this page's.
    form = doc.at_css("form#new-job-form")
    refute_nil form, "the job form must exist"
    html = form.to_html

    # The one field that must post. A structural rewrite that moved the textarea
    # across the form boundary would drop it silently from the POST, which is
    # exactly the failure this assertion exists for.
    assert_includes html, 'name="job[spec]"',
                    "the contract textarea must post as job[spec]"
    # ...and the opt-in, which composes one key into that textarea, lives inside
    # the same form as the field it writes to.
    assert_includes html, 'id="proof_variants"'
    refute_nil form.at_css("#proofVariantsBlock"), "the opt-in belongs to the form it configures"
    refute_nil form.at_css("#help-proof-variants"), "and so do its notes"
  end

  test "the shipped script composes the opt-in into validation.variants, and nothing else" do
    code = script(doc)

    # The exact composition statements, asserted as the JSON the contract
    # specifies: `variants` under `validation`, set only when the control is
    # unticked-and-inapplicable-absent. A label check would not catch a rewrite
    # that stopped writing it; this does.
    assert_includes code, "boxOn('proof_variants')",
                    "the composition must read the control's own value"
    assert_includes code, "validation.variants = pvt.length ? { enabled: true, transforms: pvt } : true;",
                    "and write validation.variants — the contract's key. The bare " \
                    "`true` asks for the whole vocabulary; a named subset writes " \
                    "the OBJECT form the print check also accepts."
    assert_includes code, "spec.validation = validation;",
                    "the block it writes must be spec.validation"
    assert_includes code, "delete validation.variants",
                    "unticking must REMOVE the key, not write false"
    assert_includes code, "pvBlock.hidden",
                    "and a control that is off screen must not compose at all"
    # The names come from a box, because the vocabulary belongs to the print
    # check (a closed, ordered list it refuses an unknown name against) -- a
    # hardcoded copy here would be a second source of truth for it.
    assert_includes code, "csvNames('proof_variant_transforms')",
                    "the subset box must be what the object form is built from"

    # It is NOT a flux setting: nothing may compose a variants key anywhere else.
    refute_includes code, "flux.variants"
    refute_includes code, "print.variants"
  end

  test "the shipped script composes flux.modifiers, flux.modifier_scales and flux.vae, omitting blanks" do
    code = script(doc)
    assert_includes code, "b.modifiers = mods;", "an array under flux.modifiers"
    assert_includes code, "b.modifier_scales = scales;", "an object, only when a scale was typed"
    assert_includes code, "b.vae = vae;", "a string"
    # Omission, not emptiness: an absent key means the service's own default.
    assert_includes code, "if (mods.length) b.modifiers = mods;"
    assert_includes code, "if (vae) b.vae = vae;"
    # And a scale is only composed for a modifier that is actually selected.
    assert_includes code, "if (selected.indexOf(key) === -1) return;"
  end

  test "the JS's contract ids are the stable ones the brief names" do
    %w[flux_modifiers flux_vae flux_modifier_scales proof_variants].each do |id|
      refute_nil doc.at_css("##{id}"), "##{id} is part of the scripts' contract and must exist"
    end
  end

  # ---- the raster-pass panel: every key its writer reads has a control ------
  #
  # prepExpandBlock() and rasterPrepBlock() compose print.prep_expand and the two
  # top-level prep switches. A key whose control is missing is not merely
  # unexposed: the boxOn()/fieldValue() read returns false/'' and the block is
  # composed with a value nobody chose. Three of these were exactly that —
  # pe_tune_sheet and pe_nr_verify were read but did not exist (so every tune
  # block turned the bench's contact sheet OFF, and every node_reduce block
  # wrote verify: false against a documented default of true).

  test "the raster-pass panel shows every control its writer reads" do
    panel = doc.at_css("#flux-settings-popup")
    refute_nil panel
    %w[pe_opaque_bg pe_prep_colors pe_filters pe_filters_presets pe_filters_sheet
       pe_filters_alpha pe_filters_spec pe_tune pe_tune_presets pe_tune_cells
       pe_tune_sheet pe_tune_speckle pe_tune_hier pe_tune_nr pe_nr pe_nr_nodes
       pe_nr_tolerance pe_nr_tolerance_cap pe_nr_verify].each do |id|
      refute_nil panel.at_css("##{id}"), "##{id} is read by the writer and must exist in the panel"
    end

    # The two switches that were read-but-missing now exist, and default to the
    # DOCUMENTED default rather than to whatever an absent element implies.
    assert panel.at_css("#pe_tune_sheet")["checked"],
      "the tune contact sheet defaults ON (the bench writes one) — it used to be an absent element, so boxOn() forced it off"
    assert panel.at_css("#pe_nr_verify")["checked"],
      "verify defaults ON — node_reduce's own default is verify, so the popup used to compose verify: false"
    refute panel.at_css("#pe_opaque_bg")["checked"], "assume_opaque_bg is false by default"
    refute panel.at_css("#pe_filters_alpha")["checked"], "keep_alpha is off by default"
    refute panel.at_css("#pe_tune_nr")["checked"], "with_node_reduce costs job time, so it is opt-in"
  end

  test "the prep switches are composed at the top level of print, and omitted when untouched" do
    code = script(doc)
    assert_includes code, "rp.assume_opaque_bg = true",
      "assume_opaque_bg is a print key, not a prep_expand sub-key"
    assert_includes code, "rp.prep_colors = null",
      "null is the documented 'no quantisation' and must survive as null"
    assert_includes code, "if ('assume_opaque_bg' in rp) spec.print.assume_opaque_bg = rp.assume_opaque_bg;",
      "an untouched switch must not be written at all"
    assert_includes code, "if ('prep_colors' in rp) spec.print.prep_colors = rp.prep_colors;"
    # ...and a raster-only run (no tracing) drops them with the benches.
    assert_includes code, "delete spec.print.assume_opaque_bg;"
    assert_includes code, "delete spec.print.prep_colors;"

    %w[pe_filters_alpha pe_filters_spec pe_tune_speckle pe_tune_hier
       pe_tune_nr pe_nr_tolerance pe_nr_tolerance_cap].each do |id|
      assert_includes code, "'#{id}'", "the panel control #{id} must be wired to writePanels"
    end

    # A cleared speckle box asks for the tool's own list. Number('') is 0, which
    # is a real speckle value, so the blank has to be dropped BEFORE the numeric
    # coercion or a blank box posts `filter_speckle: [0]`.
    assert_match(/function csvNums\(id\) \{\s*\n\s*\/\/[^\n]*\n(\s*\/\/[^\n]*\n)*\s*return fieldValue\(id\)\.split\(','\)\.map\(function \(s\) \{ return s\.trim\(\); \}\)\s*\n\s*\.filter\(function \(s\) \{ return s\.length > 0; \}\)/, code,
      "csvNums must drop blank entries before Number() turns them into 0")
  end

  test "the flux model select still offers the whole registry, new families included" do
    models = doc.css("#flux_model option").map { |o| o["value"] }
    assert_equal FluxConf::MODELS.keys, models
    assert_includes models, "sana-sprint-0.6b"
    assert_includes models, "ssd-1b"

    # The flags that drive the negative-prompt and strength fields follow the
    # registry, so the new rows cannot arrive without their gates.
    FluxConf::MODELS.each do |key, spec|
      option = doc.at_css("#flux_model option[value='#{key}']")
      if spec["negative_prompt"]
        assert_equal "1", option["data-negprompt"], "#{key} takes a negative prompt"
      else
        assert_nil option["data-negprompt"], "#{key} must not advertise one"
      end
      if spec["img2img_strength"]
        assert_equal "1", option["data-img2img"], "#{key} img2img takes a strength"
      else
        assert_nil option["data-img2img"], "#{key} must not advertise one"
      end
    end
  end

  # ISSUE #61: the option list is now RENDERED from FluxConf::MODELS rather than
  # hand-typed, so the assertion that matters is the served page against the
  # registry -- including the flag combinations that are easy to get wrong by
  # eye. Each of the three spot-checks below is a NEGATION: a model with a
  # different flag set, so a loop that hardcoded one flag for every option, or
  # dropped the third, fails here rather than rendering a plausible list.
  test "each served option carries its OWN gate flags, checked against the registry" do
    FluxConf::MODELS.each do |key, spec|
      option = doc.at_css("#flux_model option[value='#{key}']")
      refute_nil option, "#{key} must be offered by the form"
      if spec["multi_reference"]
        assert_equal "1", option["data-multiref"],
                     "#{key}'s multi-reference gate must follow the registry's own flag"
      else
        assert_nil option["data-multiref"], "#{key} must not advertise multi-reference"
      end
      if spec["negative_prompt"]
        assert_equal "1", option["data-negprompt"],
                     "#{key}'s negative-prompt gate must follow the registry's own flag"
      else
        assert_nil option["data-negprompt"], "#{key} must not advertise a negative prompt"
      end
      if spec["img2img_strength"]
        assert_equal "1", option["data-img2img"],
                     "#{key}'s img2img gate must follow the registry's own flag"
      else
        assert_nil option["data-img2img"], "#{key} must not advertise an img2img strength"
      end
    end

    # klein-4b: NO negative prompt, NO img2img strength, YES multi-reference.
    klein = doc.at_css("#flux_model option[value='klein-4b']")
    assert_nil klein["data-negprompt"], "klein is distilled: CFG never runs, so there is no negative prompt"
    assert_nil klein["data-img2img"], "and no img2img strength on the klein pipeline"
    assert_equal "1", klein["data-multiref"], "but multi-reference editing IS built in"

    # sdxl-1.0: BOTH a negative prompt and an img2img strength, NO multi-reference.
    sdxl = doc.at_css("#flux_model option[value='sdxl-1.0']")
    assert_equal "1", sdxl["data-negprompt"], "SD-style, so it takes a real negative prompt"
    assert_equal "1", sdxl["data-img2img"], "and an img2img strength"
    assert_nil sdxl["data-multiref"], "but it is a single-reference model"

    # sana: img2img ONLY -- no negative prompt (the pipeline has no such
    # parameter) and no multi-reference.
    sana = doc.at_css("#flux_model option[value='sana-sprint-0.6b']")
    assert_nil sana["data-negprompt"], "Sana has no negative_prompt parameter at all"
    assert_equal "1", sana["data-img2img"], "but it DOES take an img2img strength"
    assert_nil sana["data-multiref"]

    # The two hosted Novita models carry NO data flag: the loop must yield that
    # from the registry rather than from a special case, and their output is
    # governed by the vendor's terms.
    %w[ming-image-0.1-design ming-image-0.1-design-layer].each do |key|
      hosted = doc.at_css("#flux_model option[value='#{key}']")
      %w[data-negprompt data-img2img data-multiref].each do |attr|
        assert_nil hosted[attr], "#{key} is hosted: the registry carries no #{attr} for it"
      end
    end
  end

  # The curated label is DISPLAY, and it is the operator-facing half of each
  # option: "klein-4b — Apache-2.0, commercial OK". It comes from the entry's
  # own `select_label`, so a model whose family detail changed (the Gemma-2
  # encoder, the 32/512/1MP rules, the hosted split) must say so here, and a
  # loop that dropped the label or substituted a poorer one fails this.
  test "each served option's label carries the registry's own curated text" do
    FluxConf::MODELS.each do |key, spec|
      option = doc.at_css("#flux_model option[value='#{key}']")
      assert_equal "#{key} — #{spec['select_label']}", option.text.strip,
                   "#{key}'s option text is its key and its own select_label"
    end

    # The family detail that a derived label would LOSE, pinned literally so a
    # "generate the label from the licence field" refactor cannot pass quietly.
    assert_equal "klein-4b — Apache-2.0, commercial OK",
                 doc.at_css("#flux_model option[value='klein-4b']").text.strip
    assert_includes doc.at_css("#flux_model option[value='sana-sprint-0.6b']").text,
                    "Gemma-2 encoder",
                    "the Sana row must keep its encoder detail, not just a licence"
    assert_includes doc.at_css("#flux_model option[value='ming-image-0.1-design']").text,
                    "Novita AI hosted",
                    "the hosted row must say it is hosted, not imply a local checkpoint"
  end

  # Which option the form opens on. Blank `@flux_model` means the registry's
  # own default; a carried model means that one; an unknown one is dropped by
  # the controller and therefore falls back to the default too -- the same
  # behaviour the hand-written list had, so the loop must reproduce it exactly.
  test "the select opens on the registry default, and on the carried model when there is one" do
    assert_equal FluxConf::DEFAULT_MODEL_KEY, doc.at_css("#flux_model option[selected]")["value"],
                 "with no carried model the form must open on the REGISTRY default"

    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    begin
      post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
      get new_job_path(flux_model: "sana-sprint-1.6b"), headers: { "User-Agent" => MODERN_UA }
      assert_response :success
      carried = Nokogiri::HTML(response.body)
      selected = carried.css("#flux_model option[selected]")
      assert_equal 1, selected.size, "exactly one option is selected"
      assert_equal "sana-sprint-1.6b", selected.first["value"],
                   "the carried model is the selected one"

      # An unknown carried model is dropped by the controller, so it falls back
      # to the registry default -- and the loop must not then select the
      # default a SECOND time by leaving klein marked as well.
      get new_job_path(flux_model: "no-such-model"), headers: { "User-Agent" => MODERN_UA }
      assert_response :success
      unknown = Nokogiri::HTML(response.body)
      selected = unknown.css("#flux_model option[selected]")
      assert_equal 1, selected.size, "exactly one option is selected"
      assert_equal FluxConf::DEFAULT_MODEL_KEY, selected.first["value"],
                   "an unknown carried model must be dropped back to the registry default"
    ensure
      ENV["CHOPSHOP_PASSWORD"] = original
    end
  end
end

# The JSON page builds the SAME contract, so it must compose the same two
# additions — otherwise the two pages disagree about the one thing they share.
class ProofVariantsSpecBuilderTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def page
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    get json_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  end

  def code(doc) = doc.css("script").map(&:text).join("\n")

  test "the builder offers the opt-in, labelled with the key it writes" do
    doc = page
    box = doc.at_css("#f_proof_variants")
    refute_nil box, "the builder must offer the same opt-in as Run Job"
    assert_equal "checkbox", box["type"]

    # The field is labelled with the contract key, so the help below can only
    # ever document this one field — the rule the JSON page's help test enforces.
    label = doc.css(".card label[for='f_proof_variants']").first
    refute_nil label
    assert_equal "validation.variants", label.text.strip

    help = doc.at_css("#help-print")
    refute_nil help
    assert_includes help.css("dt").map { |d| d.text.strip }, "validation.variants",
                    "the card's own help must document it, or the page's help test fails"
  end

  test "the builder composes validation.variants only when the opt-in is ticked" do
    text = code(page)
    assert_includes text, "spec.validation = { run_preflight: true, flag_on_any_failure: true, auto_retry_limit: 3 };"
    assert_includes text, "if ($('f_proof_variants').checked) {",
                    "the builder writes the same key the Run Job page does, and only when asked"
    assert_includes text, "spec.validation.variants = pvt.length ? { enabled: true, transforms: pvt } : true;",
                    "blank asks for the whole vocabulary (the bare true); a named " \
                    "subset writes the {enabled, transforms} object the runner accepts"
    assert_includes text, "#f_proof_variants",
                    "and the control must be wired to rebuild the contract"
    assert_includes text, "#f_pv_transforms",
                    "the subset box must rebuild it too, or a typed subset is ignored"
    assert_includes text, "var pvt = nameList(val('f_pv_transforms'));",
                    "and its names are parsed as a list, not sent as one string"

    refute_includes text, "spec.flux.variants"
    refute_includes text, "spec.print.variants"
  end
end
