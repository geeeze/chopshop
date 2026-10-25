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
    assert_equal %w[MODELS DATASETS JSON CHANGE], pair.css(".head-action").map { |b| b.text.strip },
      "MODELS · DATASETS · JSON · CHANGE. DATASETS joined the pair when the library moved " \
      "onto this page: a prompt is taken FROM it and generated WITH flux, so it " \
      "belongs to this head rather than to a nav entry of its own. CHANGE is the " \
      "#43 where-to-change table, which is the head's own affordance and so sits " \
      "in the same cell as the reference pair."

    blurb = row.at_css(".page-head-blurb")
    refute_nil blurb, "the blurb must be inside the row"
    assert_equal row.element_children.last, blurb,
      "and LAST in it, or the media query drops it below the buttons on a phone"
  end

  # The model this page shows is the model a generation runs. The head's Run Job
  # used to be a BARE new_job_path, so an operator who picked a hosted model here
  # filed a job on the form's own default (klein-4b) and was told nothing —
  # measured: "i tried setting it in the flux page and it didnt work, it just ran
  # a klein task. i wanted the ming models".
  test "Run Job carries this page's model choice into the form" do
    html = doc.to_html

    assert_match(/id="fluxRunJobLink"/, html,
      "the head's Run Job link must be reachable by the script that carries the model")
    # The hand-off itself: the link's href is rewritten from the model control.
    assert_match(/data-flux-field="model"/, html,
      "the page's model control is what the link reads")
    assert_match(/flux_model=/, html,
      "the link must carry the chosen model as flux_model, or the form never hears it")
    assert_match(/new_job_path|jobs\/new/, html,
      "the link still targets the Run Job form")
  end
  # The other half — that the carried value is validated against the registry and
  # that an unknown one changes nothing — is pinned where it can be OBSERVED
  # rather than grepped for: test/controllers/flux_job_test.rb requests
  # new_job_path(flux_model: …) and reads the rendered select.

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
    #
    # The long answer moved into the hint registry (#41): the blurb carries the
    # one-line `line`, and the full sentence is the detail its `?` opens. Read
    # the popup, not the blurb, or this asserts on the short version only.
    detail = doc.at_css("#help-tip-flux-page .popup-body").text.squeeze(" ").strip
    assert_match(/generates nothing itself|configures that service/i, detail,
      "the detail must say this page runs nothing")
    assert_match(/prompt/i, detail, "and must name the prompt")
    assert_match(/Run Job/, detail, "and say where it is")

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
                    sana-sprint-0.6b sana-sprint-1.6b ssd-1b z-image-turbo
                    ming-image-0.1-design ming-image-0.1-design-layer], options
    assert_equal FluxConf::MODELS.keys, options
  end

  # ISSUE #61: the MODELS popup is now ONE rendered row per registry entry
  # instead of eleven hand-written blocks. The risk a refactor like this runs is
  # not a missing row -- it is a row that renders but has quietly LOST what the
  # hand-written one said (the licence pill, the repo id, the schedule, the
  # curated note, the negative-prompt verdict, the judgement sentence). So every
  # piece of content the old rows carried is asserted here, per row, against
  # the constants rather than against a copy typed into the test.
  test "the popup renders one row per registered model, in registry order, carrying every fact" do
    popup = doc.at_css("#flux-models-popup")
    refute_nil popup, "the MODELS popup must be on the page"

    # ONE row per entry, in the registry's own order. The order is asserted
    # because the popup is read as a list: a model moved out of place is still
    # documented but no longer where the registry says it is.
    keys = popup.css(".jev-help-k").map { |k| k.text.strip }
    assert_equal FluxConf::MODELS.keys, keys,
                 "one .jev-help-row per registered model, in registry order"

    FluxConf::MODELS.each do |key, spec|
      row = popup.css(".jev-help-row").find { |r| r.at_css(".jev-help-k").text.strip == key }
      refute_nil row, "#{key} must have a .jev-help-row of its own"
      text = row.text.gsub(/\s+/, " ")

      # The licence, as a pill, with the right colour class. A hosted model's
      # output is under the vendor's terms, so its pill is the fail colour --
      # which is what tells the operator the output is not theirs to sell.
      pill = row.at_css(".status-pill")
      refute_nil pill, "#{key} must carry a licence pill"
      assert_equal spec["licence_pill"], pill.text.strip,
                   "#{key}'s pill text is its own licence_pill"
      expected_class = spec["commercial_ok"] ? "status-pass" : "status-fail"
      assert_includes pill["class"].split, expected_class,
                      "#{key} is commercial_ok=#{spec['commercial_ok']}, so its pill is #{expected_class}"
      assert_includes text, "commercial use OK", "#{key} is commercial-usable and must say so" if spec["commercial_ok"]

      # The facts, straight from the entry: repo, params, VRAM, weights and the
      # model's OWN schedule. The hosted pair has no checkpoint and no step or
      # guidance control at all, so its row says that instead of a weights line
      # or a schedule it cannot honour.
      assert_includes text, spec["repo_id"], "#{key}'s row must name its repo"
      if spec["backend"] == "novita"
        assert_includes text, "no local VRAM or weights",
                          "#{key} is hosted: there is nothing to download, and the row must say so"
        assert_includes text, "reached over HTTP",
                          "#{key} is hosted: the row must name the endpoint it reaches over HTTP"
      else
        assert_includes text, "VRAM", "#{key} runs locally, so its row states its VRAM"
        assert_includes text, spec["distilled"] ? "(distilled)" : "(undistilled)",
                          "#{key}'s row must say whether the checkpoint is distilled"
        assert_includes text, spec["default_steps"].to_s, "#{key}'s row must state its steps"
        assert_includes text, spec["default_guidance"].to_s, "#{key}'s row must state its guidance"
      end

      # The curated prose the hand-written row carried, now the entry's own
      # `popup_note`: a derived substitute would LOSE the family detail.
      assert_includes text, spec["popup_note"].gsub(/\s+/, " "),
                      "#{key}'s row must carry its own popup_note verbatim"

      # The negative-prompt verdict, per model: this is the one that has to
      # differ per row, and the partial is what makes it so.
      if FluxConf.default_negative_prompt_for(key).present?
        assert_includes text, "a blank is NOT", "#{key} takes the print default and must say so"
      else
        assert_includes text, "no negative prompt of its own",
                            "#{key} inserts nothing, so its row must not imply a default"
      end

      # And the judgement sentence, still sourced from QUALITY.
      assert_includes text, FluxConf::QUALITY[key].gsub(/\s+/, " "),
                      "#{key}'s judgement sentence must be on its own row"
    end
  end

  # The licence sentence and the non-commercial detail are the point of the
  # popup, and they were the easiest prose to lose in a loop rewrite: the
  # sdxl-turbo row is the only one that says NON-COMMERCIAL, names the licence
  # in full, and states the acknowledgement gate.
  test "the non-commercial row keeps its licence sentence, its full licence name and its acknowledgement gate" do
    popup = doc.at_css("#flux-models-popup")
    row = popup.css(".jev-help-row").find { |r| r.at_css(".jev-help-k").text.strip == "sdxl-turbo" }
    refute_nil row, "sdxl-turbo must have a row of its own"
    text = row.text.gsub(/\s+/, " ")

    assert_includes text, "NON-COMMERCIAL", "the pill says so"
    assert_includes text, FluxConf::MODELS["sdxl-turbo"]["licence"],
                    "the licence is named in full, not abbreviated"
    assert_includes text, "Commercial use of its output requires a licence from Stability AI",
                    "the commercial limit is stated where someone will see it"
    assert_includes text, "CHOPSHOP_FLUX_ACK_NONCOMMERCIAL",
                    "and the acknowledgement that gates loading it"

    # And it is the ONLY non-commercial LOCAL row carrying that licence: the
    # pill class is the fail colour there and on the two hosted rows, which is
    # what makes the page's "every checkpoint here but sdxl-turbo" sentence true.
    fails = popup.css(".status-pill.status-fail").map { |p| p.text.strip }
    assert_equal 3, fails.size,
                 "the three non-commercial entries: sdxl-turbo and the two hosted Novita models"
    assert_includes fails, "NON-COMMERCIAL"
  end

  # "The default" is a per-row claim, and only ONE row may carry it: the
  # registry's own DEFAULT_MODEL_KEY. A blanket "the default" on every row, or
  # a literal typed into the view, both fail here.
  test "exactly one row says it is the default, and it is the registry's own default" do
    popup = doc.at_css("#flux-models-popup")
    marked = popup.css(".jev-help-row").select { |r| r.text.include?("the default") }
    assert_equal 1, marked.size, "one and only one row may say it is the default"
    assert_equal FluxConf::DEFAULT_MODEL_KEY, marked.first.at_css(".jev-help-k").text.strip,
                 "and it is the registry's default model, not a hand-typed key"
  end

  # The popup is the ONE place the registry's prose lives now, so the sentences
  # an operator reads there -- the Gemma-2 pass-through, the resolution rules,
  # the measured guidance difference -- must survive the rewrite. These are the
  # lines the hand-written rows carried that a summarising loop would drop.
  test "the rows keep the family-detail prose the hand-written rows carried" do
    body = doc.at_css("#flux-models-popup").text.gsub(/\s+/, " ")

    assert_includes body, "Gemma-2",
                    "the Sana rows must say the text encoder is Gemma-2, not just Apache-2.0"
    assert_includes body, "32-multiples",
                    "and Sana's own resolution rules, which are not klein's"
    assert_includes body, "512 floor"
    assert_includes body, "re-bins a size it has no bucket for",
                    "the resolution-binning caveat is why the returned size can differ"
    assert_includes body, "guidance is EMBEDDED",
                    "and that Sana honours guidance, unlike klein"
    assert_includes body, "MEASURED: guidance 0.0 vs 4.0",
                    "Z-Image's measured guidance difference, which is the counter-intuitive fact"
    assert_includes body, "POST /images/generations",
                    "the hosted row must name the endpoint it reaches"
    assert_includes body, "POST /images/edits",
                    "and the layer-split endpoint, which takes exactly one reference"
  end

  # The CARDS prose quoted a fixed count ("EIGHT are registered") while the
  # registry carries eleven. It is interpolated from MODELS.size now, so the
  # number on the served page cannot go stale -- but assert it is the true one,
  # because an interpolated count that names the wrong constant is still wrong.
  test "the Model card's help names the true number of registered models" do
    help = FluxConf::CARDS.flat_map { |c| c[:fields] }.find { |f| f[:label] == "model" }
    refute_nil help
    assert_includes help[:help], "#{FluxConf::MODELS.size} are registered",
                    "the help must state the registry's own size, interpolated, not a literal"
    refute_includes help[:help], "EIGHT are registered",
                    "a fixed count goes stale the moment the registry grows"
  end

  # -- the quality half: what each model is good at, and its weak spot --------
  #
  # The numbers were already on these cards; the operator's actual question at
  # the form is which one to reach for and how to get a good result from it. The
  # sentences come from chopshop-flux's docs/MODELS.md, and each one is pinned
  # against FluxConf::QUALITY rather than against a copy typed into the test, so
  # a sentence that stops being rendered fails here.

  test "every registered model carries a judgement sentence on the served page" do
    body = doc.at_css("#flux-models-popup").text.gsub(/\s+/, " ")

    assert_equal FluxConf::MODELS.keys, FluxConf::QUALITY.keys,
      "the quality sentences and the registry must be the same set of models — a " \
      "model mirrored without a sentence would render an empty line, and a sentence " \
      "for a model the service does not register would be a claim about nothing"

    FluxConf::QUALITY.each do |key, sentence|
      refute_nil sentence.to_s.strip.match(/\A\S/), "#{key}'s sentence must not be blank"
      assert_includes body, sentence.gsub(/\s+/, " "),
        "#{key}'s judgement sentence must be on the served card"
    end

    # And each one says what it is good for AND where it disappoints: a card with
    # only praise is a brochure, which is the thing the numbers alone were not.
    FluxConf::QUALITY.each do |key, sentence|
      assert_match(/Where it fits:/, sentence, "#{key} must say what it is for")
      assert_match(/Weak spot/, sentence, "#{key} must state its weak spot")
    end
  end

  test "the two measured, counter-intuitive facts are on the page" do
    # A distilled checkpoint IGNORES guidance and more steps do not help it, and
    # the pipeline class's defaults are the BASE model's schedule. Both are
    # MEASURED and both are things an operator would otherwise get wrong.
    body = doc.text.gsub(/\s+/, " ")

    assert_match(/distilled/i, body)
    assert_match(/more steps do NOT help|do NOT help/i, body,
      "the page must say more steps do not help a distilled checkpoint")
    assert_match(/guidance is ignored on\s+klein-4b and sdxl-turbo/i, body,
      "guidance is ignored on the CFG-less distilled pair, and honoured where it is embedded")
    assert_match(/34\.38/, body,
      "the measured guidance difference on klein-4b-base is what makes the " \
      "undistilled half a real difference rather than a claim")
    assert_match(/speedup can be claimed on this box/i, body,
      "no step-count speedup may be claimed under CPU offload")
  end

  test "the tips block is on the served page, with its own ? and all four subjects" do
    card = doc.at_css("[data-flux-tips]")
    refute_nil card, "the tips block must be on the page, not only in a sibling repo's docs"

    assert_equal FluxConf::TIPS[:items].size, card.css(".jev-derived").size,
      "one panel per subject"
    labels = card.css(".jev-derived-label").map { |l| l.text.strip }
    assert_equal FluxConf::TIPS[:items].map(&:first), labels

    button = card.at_css(".help-btn")
    refute_nil button, "the tips card carries a ? like every other card"
    block = doc.at_css("##{button["data-help-target"]}")
    refute_nil block, "#{button["data-help-target"]} must exist as rendered help"
    assert_equal FluxConf::TIPS[:entries].size, block.css("dt").size,
      "and the ? is fed from TIPS[:entries] rather than from a field list"

    # Full width: not in the 2x2 setting grid, or it unbalances the rows the way
    # the Checks card did.
    assert_nil doc.at_css(".grid-2 [data-flux-tips]"),
      "the tips block is outside the four-card grid"

    # The four subjects, in the operator's words. These are the sentences the
    # brief is about, so they are asserted on the SERVED page rather than on the
    # view file.
    body = card.text.gsub(/\s+/, " ")
    assert_match(/distilled vs undistilled/i, body)
    assert_match(/negative prompt/i, body)
    assert_match(/sdxl-1\.0/, body, "the entries with a REAL negative prompt are named")
    assert_match(/sd-1\.5/, body)
    assert_match(/ssd-1b/, body)
    assert_match(/native size/i, body)
    assert_match(/1024 px on klein/, body, "the native size is named, not implied")
    assert_match(/512 px on sd-1\.5 and the Sana entries/, body)
    assert_match(/print formula/i, body)
    assert_match(/Name the ink count/i, body, "the ink count is the first thing to name")
    assert_match(/flat colour/i, body)
    assert_match(/thick\s+uniform outlines/i, body)
    assert_match(/plain white ground/i, body)
    assert_match(/no gradients/i, body)
    assert_match(/dpi 300/, body,
      "the print formula points at the pipeline's own spec instead of inventing a " \
      "second set of numbers")
  end

  # -- the GPU-contention guard: issue #13's page half ----------------------
  #
  # The card is shared, and a busy card is now a refusal rather than a bad frame.
  # The env knobs and the 503 kind are the service's (config.py + docs/API.md),
  # and the parity test compares this inventory against config.py — so this test
  # is about the SERVED page carrying them, which is what #13 recorded as missing.

  test "the GPU card is on the served page with every guard knob in its help" do
    card = doc.at_css("[data-flux-gpu]")
    refute_nil card, "the guard must be on the page: a shared card is where a refusal is explained"

    labels = card.css(".field label").map { |l| l.text.strip }
    assert_equal FluxConf::GUARD[:fields].map { |f| f[:label] }, labels

    button = card.at_css(".help-btn")
    refute_nil button
    help = doc.at_css("##{button["data-help-target"]}")
    refute_nil help, "#{button["data-help-target"]} must exist as rendered help"
    named = help.css("dt").map(&:text).join(" ")

    FluxConf::GUARD[:fields].each do |f|
      assert_includes named, f[:env],
        "#{f[:label]} is #{f[:env]}, which the help does not name"
      assert_includes doc.text, f[:env],
        "#{f[:env]} must be on the served page, not only in the model file"
    end

    assert_nil doc.at_css(".grid-2 [data-flux-gpu]"),
      "the GPU card is full width, like the Checks and deployment cards"

    # The refusal itself, and where the gate is legible without one.
    body = card.text.gsub(/\s+/, " ")
    assert_match(/503 gpu_busy/, body,
      "the refusal kind is the service's — retry, do not fix the request")
    assert_match(/shared/i, body, "the card is shared: that is why the guard exists")
    assert_includes doc.text.gsub(/\s+/, " "), "gpu_guard",
      "and /health's gpu_guard block is where a busy card is legible"

    # The generated conf emits the same knobs, in the service's names — the copy
    # an operator pastes into whatever supervises the service. Asserted on the
    # SERVED response body, which carries the page's inline script.
    %w[CHOPSHOP_FLUX_GUARD CHOPSHOP_FLUX_GUARD_VRAM_GB CHOPSHOP_FLUX_GUARD_WAIT
       CHOPSHOP_FLUX_GUARD_POLL CHOPSHOP_FLUX_LMSTUDIO_URL].each do |env|
      assert_includes response.body, env, "#{env} must reach the conf JSON"
    end
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

  # #22: the blank negative-prompt box is NOT "no negative prompt", and the page
  # has to be able to say which model it is talking about.
  #
  # The service attaches a print-tuned default on the four entries whose
  # negative_prompt is real, and inserts NOTHING on the other five. Those are
  # different claims about the same empty box, and only one is true for any given
  # model -- so the sentence is per model, read off the mirror, and a blanket
  # "a default is applied" would be a lie on half the page.
  test "the page says, per model, whether a blank negative prompt gets a default or none" do
    body = doc.text.gsub(/\s+/, " ")

    # The entries that DO get one name the default verbatim. Quoted from the
    # mirror, so a retune in the service is a retune here or a parity failure.
    %w[sdxl-1.0 sdxl-turbo sd-1.5 ssd-1b].each do |key|
      assert_equal FluxConf::PRINT_NEGATIVE_PROMPT,
                   FluxConf.default_negative_prompt_for(key),
                   "#{key} carries the print default in the mirror, so the page has " \
                   "one to quote"
    end
    assert_includes body, FluxConf::PRINT_NEGATIVE_PROMPT,
                    "the page states the default the service would send, not a " \
                    "paraphrase of it"

    # And the entries that get nothing must say NOTHING -- asserted on the
    # MIRROR rather than on the prose, because the prose is generated from it and
    # asserting the generated text against itself proves nothing.
    %w[klein-4b klein-4b-base sana-sprint-0.6b sana-sprint-1.6b z-image-turbo].each do |key|
      assert_nil FluxConf.default_negative_prompt_for(key),
                 "#{key} has no negative_prompt parameter at all, so the service " \
                 "inserts nothing and claiming a default would be a false claim"
    end

    # Both halves are RENDERED, and on EVERY entry row: a row that omits the
    # sentence is exactly the silent case the issue is about, and a blanket
    # sentence on the rows that insert nothing is the false claim.
    with_default, without = FluxConf::MODELS.keys.partition do |key|
      FluxConf.default_negative_prompt_for(key).present?
    end
    assert_equal 4, with_default.size, "the service's registry has four entries " \
                                         "with a real negative prompt"
    assert_equal 7, without.size, "and seven that insert nothing"

    # Counted in the DOM, per row, rather than by counting phrases in the whole
    # body: a phrase appearing once somewhere proves nothing about nine rows.
    # Selected on the KEY cell, not on the row wrapper -- the ninth entry is a
    # `.jev-help-pair` rather than a `.jev-help-row`, and a selector that missed
    # it would report eight verdicts as a pass.
    keys = doc.css(".jev-help-k")
    rows = keys.map { |k| [k.text.strip, k.parent] }
    assert_equal FluxConf::MODELS.keys.sort, rows.map(&:first).sort,
                 "every mirrored model has a help row, and each one gets a verdict"
    rows.each do |key, row|
      text = row.text.gsub(/\s+/, " ")
      if FluxConf.default_negative_prompt_for(key).present?
        assert_includes text, "a blank is NOT",
                        "#{key} gets the print default, so its row must say so"
      else
        assert_includes text, "no negative prompt of its own",
                        "#{key} inserts nothing, so its row must not imply a default"
      end
    end
  end

  test "the page says how to send NO negative prompt, because a blank box is not it" do
    body = doc.text.gsub(/\s+/, " ")

    # `""` is the way the service takes "none", and an operator who cannot see
    # that will keep leaving the box blank and keep getting the default.
    assert_match(/empty string sends none/i, body,
                 "the page must name the empty string as the way to send none")
    assert_match(/empty string, not a blank field/i, body,
                 "the distinction is the whole point: blank is a default, \"\" is none")

    # And the field help says the same, since the form is where the box is.
    help = FluxConf::CARDS.flat_map { |c| c[:fields] }
                        .find { |f| f[:label] == "negative_prompt" }
    refute_nil help, "the negative prompt field is still on the page"
    assert_match(/Leave it BLANK/, help[:help],
                 "the help must say blank means the default, or the box lies by omission")
    assert_match(/print-tuned default/, help[:help],
                 "and it must name the print default it would attach, so a blank " \
                 "box is a stated default rather than a silent one")

    # The per-model field carries it as DATA, read, not edited -- a blanket
    # single default on the card would be a false claim on the five entries that
    # insert nothing.
    mirror = FluxConf::CARDS.flat_map { |c| c[:fields] }
                           .find { |f| f[:label] == "default_negative_prompt" }
    refute_nil mirror, "the mirrored field is on the page, or the form cannot say which"
    assert_equal :static, mirror[:type],
                 "the mirror is shown as a value, not offered as an input -- " \
                 "nothing in the composer reads it, so an editable box is a lie (#16)"
    assert_equal FluxConf::PRINT_NEGATIVE_PROMPT, mirror[:default]
    assert_match(/Read, not edited/, mirror[:help],
                 "it is the mirror of what the service would apply, and says so, so " \
                 "nobody edits the mirror and wonders why the service ignores it")
  end

  # #16: the mirror is a DIV of text, so there is no control to type into. This
  # is the rendering half of the assertion above -- the model's `:static` means
  # nothing if the partial still falls through to a text input.
  test "the mirrored default negative prompt is a value on the page, not a control" do
    d = doc
    field = d.at_css("#f_flux_default_negative_prompt")
    refute_nil field, "the mirror is still rendered"
    assert_equal "div", field.name,
                 "it must be a value, not an input the operator can type into"
    assert_equal FluxConf::PRINT_NEGATIVE_PROMPT, field.text
    assert_nil field.at_css("input, select, textarea"),
               "and it carries no control of its own"
    assert_nil d.at_css("#f_flux_default_negative_prompt[readonly]"),
               "a readonly input would still read as a control; the value is plain text"
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
    assert_equal %w[klein-4b klein-4b-base sana-sprint-0.6b sana-sprint-1.6b
                    ming-image-0.1-design ming-image-0.1-design-layer], no_neg.map(&:first)
    assert_equal %w[sdxl-1.0 sdxl-turbo sd-1.5 ssd-1b z-image-turbo], sd_family.map(&:first)
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
