require "test_helper"

# The FLUX page: the generation service's settings and model registry.
#
# Two things are worth pinning here. First, the page's own rule -- each card's
# "?" documents that card's fields and nothing else -- which the JSON page
# enforces by test because its cards are hand-written. On this page the cards and
# the help both render from FluxConf::CARDS, so the test is what catches a future
# hand-edit that breaks the pairing.
#
# Second, and more important: the licence. klein-4B is Apache-2.0 and sdxl-turbo
# is Stability AI Non-Commercial, and this is a print business. The page has to
# say which is which where someone will see it, and FluxConf.validate has to
# refuse the non-commercial model until it is acknowledged -- exactly as the
# service does.
class FluxPageTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def doc
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    get flux_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  # -- the page itself -----------------------------------------------------

  test "the nav carries FLUX after JSON, before JEV" do
    links = doc.css("nav.topbar .nav-links a").map { |a| [a.text.strip, a["href"]] }
    labels = links.map(&:first)
    assert_includes labels, "FLUX"
    assert_operator labels.index("FLUX"), :>, labels.index("JSON"),
      "the FLUX link goes after the JSON one"
    assert_operator labels.index("FLUX"), :<, labels.index("JEV")
    assert_equal flux_path, links.assoc("FLUX").last
  end

  test "the page head is the house shape: Run Job top, a popup pair below" do
    head = doc.at_css(".page-head")
    row = head.at_css(".page-head-row")
    assert_includes row["class"].split, "page-head-row--stacked"

    run = head.at_css(".head-action--top")
    assert_equal "Run Job", run.text.strip

    pair = head.at_css(".head-action-pair")
    refute_nil pair, "the head's popup triggers share the row-2 cell as a pair"
    assert_includes pair["class"].split, "head-action--below"
    assert_equal %w[MODELS DATASETS JSON], pair.css(".head-action").map { |b| b.text.strip },
      "MODELS · DATASETS · JSON. DATASETS joined the pair when the library moved " \
      "onto this page: a prompt is taken FROM it and generated WITH flux, so it " \
      "belongs to this head rather than to a nav entry of its own."

    blurb = row.at_css(".page-head-blurb")
    refute_nil blurb, "the blurb must be inside the row"
    assert_equal row.element_children.last, blurb,
      "and LAST in it, or the media query drops it below the buttons on a phone"
  end

  test "every card exists with a ? that points at its own help block" do
    titles = doc.css(".card[data-flux-card]").map { |c| c.at_css("h3").text.strip }
    assert_equal %w[Service Model Resolution Hand-off], titles

    doc.css(".card[data-flux-card]").each do |card|
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
    doc.css(".card[data-flux-card]").each do |card|
      title = card.at_css("h3").text.strip
      terms = help_terms(card.at_css(".help-btn")["data-help-target"])
      card_labels(card).each do |label|
        assert terms.any? { |t| t.start_with?(label) },
          "#{title} is missing help for #{label.inspect} (the help documents #{terms.inspect})"
      end
    end
  end

  test "no card's help documents a field that is not its own" do
    doc.css(".card[data-flux-card]").each do |card|
      title = card.at_css("h3").text.strip
      labels = card_labels(card)
      help_terms(card.at_css(".help-btn")["data-help-target"]).each do |term|
        assert labels.any? { |l| term.start_with?(l) },
          "#{title}'s help documents #{term.inspect}, which is not one of its fields (#{labels.inspect})"
      end
    end
  end

  test "every environment variable the service reads is named in the help" do
    # The help blocks are siblings of the cards, not inside them -- the JSON
    # page's arrangement. So gather them by each card's own target rather than
    # by looking for <dt> inside the card markup.
    named = doc.css(".card[data-flux-card]").flat_map do |card|
      help_terms(card.at_css(".help-btn")["data-help-target"])
    end.join(" ")
    FluxConf::CARDS.each do |card|
      card[:fields].each do |f|
        next unless f[:env]
        assert_includes named, f[:env],
          "#{card[:title]}/#{f[:label]} is #{f[:env]}, which the help does not name"
      end
    end
  end

  test "no ERB scaffolding leaked into the page as text" do
    # A fuzzy patch once closed an ERB comment a line early, so the comment's own
    # body rendered as visible page text ("One block per card...", and the <dt>
    # in it swallowed as a tag). Nothing else in this file noticed, because the
    # structure was still correct -- so check the text itself.
    body = doc.text
    ["<%#", "%>", "FluxConf::", "card[:", "each do |", "end %>"].each do |token|
      refute_includes body, token, "#{token} is ERB scaffolding, not page text"
    end
  end

  # -- the Checks card, which answers rather than configures ----------------

  test "the Checks card is not one of the setting cards" do
    # It answers rather than configures, so it must not sit in the 2x2 setting
    # grid -- that is the whole reason it stopped stretching the Resolution row.
    assert_equal 4, doc.css(".grid-2 .card[data-flux-card]").size,
      "only the four setting cards are in the grid"
    refute_nil doc.at_css("[data-flux-checks]"), "the Checks card is on the page"
    assert_nil doc.at_css(".grid-2 [data-flux-checks]"),
      "and it is outside the grid, or it unbalances the rows again"
  end

  test "the Checks card's own ? has help of its own" do
    # Its "?" documents what the card shows, not fields it has, so it is fed
    # from CHECKS[:entries] rather than from a card's field list -- which means
    # nothing else in this file would notice if that pairing broke.
    button = doc.at_css("[data-flux-checks] .help-btn")
    refute_nil button, "the Checks card has a ? like every other card"
    block = doc.at_css("##{button["data-help-target"]}")
    refute_nil block, "#{button["data-help-target"]} exists"
    assert_equal FluxConf::CHECKS[:entries].size, block.css("dt").size
  end

  test "the four size rules are shown on the page, in the service's order" do
    body = doc.css("[data-flux-checks] dd").map { |dd| dd.text.strip }
    assert_equal FluxConf::SIZE_RULES.map { |_, why| why.strip }, body,
      "the legend shows the service's own sentences, in its own order"
  end

  # -- where any of this runs, which was the first question the page did not
  #    answer: the settings said what to generate and nothing said where the
  #    generating happened, or that it could happen on another machine at all.

  test "the page says where things run, and that it can be one box or two" do
    card = doc.at_css("[data-flux-placement]")
    refute_nil card, "the deployment shapes must be on the page, not only in a README"

    shapes = card.css(".jev-derived-label").map { |l| l.text.strip }
    assert_equal FluxConf::PLACEMENT[:shapes].map(&:first), shapes,
      "both shapes are shown, named the way the config names them"

    prose = card.css(".jev-note").map { |p| p.text.strip }.join(" ")
    assert_match(/on the same machine/i, prose, "one shape is one box")
    assert_match(/private network/i, prose,
      "the other crosses a network, which is what makes it a second shape")
    assert_match(/token/i, prose,
      "and crossing one is why it needs a credential")

    # The variables are the entire difference between the shapes, so they have
    # to be visible on the card rather than only in the help.
    vars = card.css("dt").map { |dt| dt.text.strip }
    assert_includes vars, "CHOPSHOP_FLUX_BIND=#{FluxConf::DEFAULT_BIND}"
    assert_includes vars, "CHOPSHOP_RUNNER_FLUX_URL=http://127.0.0.1:#{FluxConf::DEFAULT_PORT}"
    assert(vars.any? { |v| v.start_with?("CHOPSHOP_FLUX_TOKEN") },
      "the split shape must name the token: a bind without one is an open GPU")
    refute_nil card.at_css(".help-btn"), "the card carries a ? like every other"
  end

  test "the deployment card's ? is fed from its own entries, not a field list" do
    button = doc.at_css("[data-flux-placement] .help-btn")
    refute_nil button
    block = doc.at_css("##{button["data-help-target"]}")
    refute_nil block, "#{button["data-help-target"]} exists"
    assert_equal FluxConf::PLACEMENT[:entries].size, block.css("dt").size
    assert_nil doc.at_css(".grid-2 [data-flux-placement]"),
      "it is full width: two columns of shapes would be a footnote in half a row"
  end

  test "the page says the service is a standard API other applications can call" do
    # The user's own words: "other applications need standard API". If that is
    # not on the page, the next person wires the studio's dialect into a service
    # that was deliberately kept general.
    html = doc.text
    assert_match(/other applications|another application|any application/i, html)
    assert_match(%r{/generate}, html)
    assert_match(%r{/edit}, html)
  end

  test "the page says where the prompt is, since it has none of its own" do
    # The first thing asked of this page: "what is it generating from? i see no
    # prompt". The page is config by design, so the answer has to be on it -- the
    # prompt is on Run Job, and a reader has to be told that rather than left to
    # conclude the service draws from nothing.
    blurb = doc.at_css(".page-head-blurb").text.squeeze(" ").strip
    assert_match(/generates nothing itself|configures that service/i, blurb,
      "the blurb must say this page runs nothing")
    assert_match(/prompt/i, blurb, "and must name the prompt")
    assert_match(/Run Job/, blurb, "and say where it is")

    # And it must actually be true: Run Job offers a prompt once a flux runner is
    # selected. Asserted in flux_job_test.rb; this is the pointer to it.
    refute_nil doc.at_css("a[href='#{new_job_path}']"),
      "the Run Job button is the route to that prompt"
  end

  # -- the licence, which is the point of the MODELS popup ------------------

  test "the Model card shows the licence live, not as a hidden footote" do
    card = doc.css(".card[data-flux-card]").find { |c| c.at_css("h3").text.strip == "Model" }
    pill = card.at_css("#fluxLicencePill")
    refute_nil pill, "the licence pill must be in the Model card"
    assert_equal "Apache-2.0", pill.text.strip
    assert_includes pill["class"].split, "status-pass"
  end

  test "the MODELS popup states both licences and the non-commercial limit" do
    # ERB wraps long sentences across source lines, so collapse whitespace before
    # matching text -- otherwise the assertion fails on a line break rather than
    # on a missing sentence.
    body = doc.at_css("#flux-models-popup").text.gsub(/\s+/, " ")

    assert_includes body, "Apache-2.0"
    assert_includes body, "Stability AI Non-Commercial Research Community License"
    assert_includes body, "NON-COMMERCIAL"
    assert_includes body, "Commercial use of its output requires a licence from Stability AI"
    assert_includes body, "CHOPSHOP_FLUX_ACK_NONCOMMERCIAL"
  end

  test "the Model select offers exactly the registered models, and the popup documents each one" do
    body = doc.at_css("#flux-models-popup").text.gsub(/\s+/, " ")
    FluxConf::MODELS.each_key do |key|
      assert_includes body, key, "#{key} must be documented in the popup"
    end
    refute_includes body, "klein-9b", "the 9B is gone: it is not a model the service registers"

    # And the select is the registry, in order: nothing registered is left out,
    # and nothing unregistered is offered. The literal is pinned as well as the
    # comparison to the constant, so a model silently DROPPED from the registry
    # (which would keep the second assertion true) is still caught here.
    options = doc.css("#f_flux_model option").map { |o| o["value"] }
    assert_equal %w[klein-4b klein-4b-base sdxl-1.0 sdxl-turbo sd-1.5
                    sana-sprint-0.6b sana-sprint-1.6b ssd-1b], options
    assert_equal FluxConf::MODELS.keys, options
  end

  test "the JSON popup opens with the conf already in it" do
    popup = doc.at_css("#flux-conf-popup")
    refute_nil popup
    assert popup["hidden"], "the popup starts hidden"
    out = popup.at_css("textarea#fluxConfOutput")
    refute_nil out, "the terminal holds the generated conf"
    assert popup.at_css(".copy-ghost"), "and carries the copy button"
    assert_includes doc.at_css(".page-head").to_s, 'data-popup="flux-conf-popup"'
  end

  test "the page passes the rules to the browser instead of restating them" do
    facts = JSON.parse(doc.at_css("script#fluxFacts").text)
    assert_equal 64, facts["constraints"]["minDimension"]
    assert_equal 16, facts["constraints"]["dimensionMultiple"]
    assert_equal 4 * 1024 * 1024, facts["constraints"]["maxPixels"]
    assert_equal FluxConf::MODELS.keys, facts["models"].keys
    # The JS must not carry its own copy of a licence or a VRAM figure.
    view = File.read(Rails.root.join("app/views/pages/flux.html.erb"))
    script = view[/<script>\n\(function \(\) \{.*?\}\)\(\);\n<\/script>/m]
    refute_nil script
    refute_includes script, "FLUX Non-Commercial", "the licence belongs in the model, not in JS"
    refute_includes script, "1024 * 1024", "the pixel cap belongs in the model, not in JS"
  end
end

# The validation, against the service's own rules. This is the page's reason to
# exist: a request the service would reject should be rejectable before you have
# started anything. The sentences are the service's.
class FluxConfValidationTest < ActiveSupport::TestCase
  def validate(**over)
    FluxConf.validate(
      width: "1024", height: "1024", images: "1",
      model_key: "klein-4b", guidance: "1.0", ack: "0", **over
    )
  end

  test "a clean request has no problems and no warnings" do
    result = validate
    assert_empty result[:problems]
    assert_empty result[:warnings]
    assert_equal 1024 * 1024, result[:pixels]
  end

  test "a dimension that is not a multiple of 16 is rejected, in the service's words" do
    result = validate(width: "1000")
    assert_includes result[:problems].join(" "), "width must be a multiple of 16, got 1000"
    assert_nil result[:pixels], "no pixel total when the size is already invalid"
  end

  test "the 4 MP cap is inclusive, because 2048x2048 IS 4 MP" do
    assert_empty validate(width: "2048", height: "2048")[:problems]
    over = validate(width: "2048", height: "2064")
    assert_includes over[:problems].join(" "), "over the 4194304 cap"
  end

  test "the minimum dimension and integer rules are enforced" do
    assert_includes validate(width: "48")[:problems].join(" "), "at least 64, got 48"
    assert_includes validate(height: "1024.0")[:problems].join(" "),
                    "height must be an integer, got 1024.0"
    assert_includes validate(images: "0")[:problems].join(" "), "images must be a positive integer"
  end

  test "the non-commercial model is refused until it is acknowledged" do
    gate = validate(model_key: "sdxl-turbo", ack: "0")
    assert_includes gate[:problems].join(" "),
                    "Stability AI Non-Commercial Research Community License"
    assert_includes gate[:problems].join(" "), "licence from the model's licensor"
    assert_includes gate[:problems].join(" "), "CHOPSHOP_FLUX_ACK_NONCOMMERCIAL=1"

    acked = validate(model_key: "sdxl-turbo", ack: "1")
    assert_empty acked[:problems], "acknowledging it is what unblocks it"
    assert_equal false, acked[:spec]["commercial_ok"]
  end

  test "guidance above 1.0 on a distilled model warns, and does not block" do
    result = validate(guidance: "3")
    assert_empty result[:problems], "it is a warning, not a refusal"
    assert_includes result[:warnings].join(" "), "guidance_scale 3 is ignored"
    assert_includes result[:warnings].join(" "), "negative prompt"
  end

  test "the undistilled base model takes real guidance without a warning" do
    result = validate(model_key: "klein-4b-base", guidance: "4.0")
    assert_empty result[:warnings], "guidance works there, so there is nothing to warn about"
    assert_equal 28, result[:spec]["default_steps"]
  end

  test "a distilled model warns against its OWN default guidance, not klein's 1.0" do
    # sdxl-turbo is distilled with default_guidance 0.0, so guidance 1.0 is
    # still ignored there even though 1.0 is klein-4b's default — and the old
    # hardcoded `!= 1.0` check would have missed it.
    turbo = validate(model_key: "sdxl-turbo", guidance: "1.0", ack: "1")
    assert_includes turbo[:warnings].join(" "), "guidance_scale 1.0 is ignored"
    # its own default is the only guidance that does NOT warn
    at_default = validate(model_key: "sdxl-turbo", guidance: "0.0", ack: "1")
    refute_includes at_default[:warnings].join(" "), "guidance_scale"
  end

  test "a negative prompt or a strength on a model without one warns, and refuses nothing" do
    klein = validate(model_key: "klein-4b", negative_prompt: "blurry", strength: "0.6")
    assert_empty klein[:problems],
      "both are warnings, not refusals: the service generates anyway and says so"
    assert_includes klein[:warnings].join(" "),
                    "negative prompt ignored: klein-4b has no negative_prompt parameter"
    assert_includes klein[:warnings].join(" "),
                    "strength ignored: klein-4b is not an SD-style img2img model"

    # sdxl-1.0 is the model both of those exist for, so a request that uses
    # them there has nothing to warn about.
    sdxl = validate(model_key: "sdxl-1.0", negative_prompt: "blurry", strength: "0.6")
    assert_empty sdxl[:problems]
    assert_empty sdxl[:warnings], "sdxl takes both, so there is nothing to report"

    # A blank is an absent one: nothing was asked for, so there is nothing to
    # ignore.
    blank = validate(model_key: "klein-4b", negative_prompt: "", strength: "")
    assert_empty blank[:warnings]
  end

  test "the registry carries the licences verbatim" do
    assert_equal "Apache-2.0", FluxConf::MODELS["klein-4b"]["licence"]
    assert_equal true, FluxConf::MODELS["klein-4b"]["commercial_ok"]
    assert_equal "Stability AI Non-Commercial Research Community License",
                 FluxConf::MODELS["sdxl-turbo"]["licence"]
    assert_equal false, FluxConf::MODELS["sdxl-turbo"]["commercial_ok"]
    assert_equal false, FluxConf::MODELS["sdxl-turbo"]["gated"],
      "it needs an acknowledgement, not a token: Hugging Face does not gate it"
    assert_equal "CreativeML Open RAIL-M License", FluxConf::MODELS["sd-1.5"]["licence"]
    assert_equal true, FluxConf::MODELS["sd-1.5"]["commercial_ok"]
  end

  test "sdxl-1.0 is commercial, SD-style, and the SD family are the ones that take a negative prompt" do
    sdxl = FluxConf::MODELS["sdxl-1.0"]
    refute_nil sdxl, "sdxl-1.0 must be in the studio registry, matching the service"
    assert_equal true, sdxl["commercial_ok"]
    assert_equal false, sdxl["distilled"]
    assert_equal true, sdxl["negative_prompt"],
      "SDXL takes a real negative prompt — the whole reason it was added"
    assert_equal true, sdxl["img2img_strength"], "SDXL img2img uses a strength"

    # Two families have NO negative_prompt parameter at all and the form must
    # never offer them the field: the kleins (Flux2KleinPipeline has none) and
    # the Sanas.
    #
    # The partition is made ON the flag itself rather than on a name prefix, and
    # that is deliberate: this test used to split on `start_with?("klein")`,
    # which silently filed every newly registered family with the SD one. The
    # Sana rows proved it — a name-prefix split would have asserted they take a
    # real negative prompt, which they do not. The flag is the thing the loops
    # below actually assert, so the partition asks about the flag.
    no_neg, sd_family = FluxConf::MODELS.partition { |_key, spec| !spec["negative_prompt"] }
    assert_equal %w[klein-4b klein-4b-base sana-sprint-0.6b sana-sprint-1.6b], no_neg.map(&:first)
    assert_equal %w[sdxl-1.0 sdxl-turbo sd-1.5 ssd-1b], sd_family.map(&:first)
    no_neg.each do |key, spec|
      assert_equal false, spec["negative_prompt"],
        "#{key} must not advertise a negative prompt (its pipeline has no such parameter)"
    end
    sd_family.each do |key, spec|
      assert_equal true, spec["negative_prompt"], "#{key} takes a real negative prompt"
      assert_equal true, spec["img2img_strength"], "#{key} img2img takes a strength"
    end
  end

  test "the constants match the service's, because they are transcribed" do
    assert_equal 64, FluxConf::MIN_DIMENSION
    assert_equal 16, FluxConf::DIMENSION_MULTIPLE
    assert_equal 4 * 1024 * 1024, FluxConf::DEFAULT_MAX_PIXELS
    assert_equal 8795, FluxConf::DEFAULT_PORT
    assert_equal "127.0.0.1", FluxConf::DEFAULT_BIND
    assert_equal "klein-4b", FluxConf::DEFAULT_MODEL_KEY
  end

  # The /flux page validates a request in the BROWSER as well as on the server,
  # and that is a second copy of the rules — the place a fix lands on one side
  # only. It happened: `FluxConf.validate` was corrected to stop calling a Sana
  # request's guidance "ignored" (guidance is embedded there and honoured), and
  # the page's own JavaScript kept the old check, so the operator was told a
  # warning the service does not produce.
  #
  # Read the VIEW from disk rather than over HTTP, the same way the script-block
  # test above does: this is a class-level fact about the shipped JavaScript, not
  # about one request's response, and the JS has no runtime here to execute it.
  test "the flux page's JavaScript carries the same guidance guard as validate" do
    view = File.read(Rails.root.join("app/views/pages/flux.html.erb"))
    script = view[/<script>\n\(function \(\) \{.*?\}\)\(\);\n<\/script>/m]
    refute_nil script, "the page's script block must still be extractable"

    # The guard must test distilled AND the absence of an embedded guidance --
    # exactly the condition in FluxConf.validate. A substring, admittedly, but it
    # is the exact token that went stale, and it fails loudly on a re-introduction.
    assert_includes script, "spec.distilled && !spec.guidance_embedded",
                    "the guidance warning must be guarded by guidance_embedded, or the " \
                    "page contradicts the service on the Sana rows"

    # And it must warn about resolution binning, as validate and the engine do.
    assert_includes script, "spec.resolution_binning",
                    "the page must surface resolution binning: a requested size can " \
                    "come back different"

    # The registry the page validates against must carry both fields, or the two
    # checks above would read `undefined` and quietly never fire.
    %w[sana-sprint-0.6b sana-sprint-1.6b].each do |key|
      assert_equal true, FluxConf::MODELS[key]["guidance_embedded"]
      assert_equal true, FluxConf::MODELS[key]["resolution_binning"]
    end
    assert_equal false, FluxConf::MODELS["klein-4b"]["guidance_embedded"]
  end
end
