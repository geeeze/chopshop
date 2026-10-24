require "test_helper"

# Two things this covers, both of which are easy to get quietly wrong:
#
# 1. ONE REQUEST TO JEV, EVER. ask_jev used to call the runner unconditionally.
#    The client avoided re-asking within a page load, but a reload, a second
#    tab or a hand-typed POST re-paid for a model call to produce an answer we
#    already held. The stored answer is now served instead, and the test counts
#    the runner calls rather than trusting the client's politeness.
#
# 2. The jobs results page's 67/33 split and the per-proof Jev buttons.
#    Jev answers live on the VALIDATION, not the job, so a single job-level
#    button would have had to pick one proof arbitrarily -- hence one button
#    per row, and one dialog per finished proof.
class JevOnceAndResultsSplitTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  ANSWERS = {
    "dominant_issue" => { "type" => "choice", "choice" => "screen_explosion",
                          "confidence" => 0.82 },
    "next_action" => { "type" => "noul", "noul" => 0.71 }
  }.freeze

  def setup
    super
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  def job_with_candidates
    Job.create!(name: "split", state: "done", source_kind: "svg",
                input_path: "/data/x.svg", stem: "split", spec: {}, runner: "mock",
                comparison: { "candidates" => [
                  { "file" => "candidate_01.svg", "hard" => 0, "advisory" => 1,
                    "layer_a" => { "status" => "pass" }, "layer_b" => { "status" => "pass" } },
                  { "file" => "candidate_02.svg", "hard" => 2, "advisory" => 0,
                    "layer_a" => { "status" => "fail" }, "layer_b" => { "status" => "warn" } }
                ] })
  end

  def proof_for(job, file, **attrs)
    job.validations.create!({ file: file, state: "done",
                              manifest: { "proof" => file.sub("candidate_", "proof_") + ".png",
                                          "summary" => { "hard" => 0, "advisory" => 1 } } }
                              .merge(attrs))
  end

  # Counts the runner calls. Minitest 6 dropped minitest/mock, so swap the
  # singleton method out and restore it by hand.
  def counting_ask_jev
    # A one-element Array, NOT a plain counter: `yield calls` hands the test a
    # SNAPSHOT of the integer, so the block's `+= 1` lands in a variable the
    # test can never see and every assertion reads 0. The block mutates this
    # object, so the test reads it live.
    calls = [0]
    original = RunnerClient.method(:ask_jev)
    RunnerClient.define_singleton_method(:ask_jev) do |validation|
      calls[0] += 1
      { answers: ANSWERS, model: "test-model", endpoint: "local",
        latency_ms: 1, verdict: { "headline" => "look_at_it" } }
    end
    yield calls
  ensure
    RunnerClient.define_singleton_method(:ask_jev, original)
  end

  # --- the one-request rule -------------------------------------------------

  test "a second ask_jev returns the stored answer without calling the runner" do
    job = job_with_candidates
    v = proof_for(job, "candidate_01.svg")

    counting_ask_jev do |calls|
      post ask_jev_validation_path(v, format: :json),
           headers: { "User-Agent" => MODERN_UA, "Accept" => "application/json" }
      assert_response :success
      first = JSON.parse(response.body)
      assert_equal 1, calls[0], "the first ask must reach the runner"
      assert_equal "look_at_it", first.dig("meta", "verdict", "headline")
      refute_empty first["cards"]

      # THE TEST: a replay must not pay for a second model call.
      post ask_jev_validation_path(v, format: :json),
           headers: { "User-Agent" => MODERN_UA, "Accept" => "application/json" }
      assert_response :success
      second = JSON.parse(response.body)

      assert_equal 1, calls[0],
                   "the runner was called again for an answer we already had"
      assert_equal first, second,
                   "a replayed request must be indistinguishable from the original"
    end

    assert v.reload.jev_answers.present?, "the answer stays stored"
  end

  test "the stored answer survives a page load, so the client never re-asks" do
    job = job_with_candidates
    v = proof_for(job, "candidate_01.svg")

    counting_ask_jev do |calls|
      post ask_jev_validation_path(v, format: :json),
           headers: { "User-Agent" => MODERN_UA, "Accept" => "application/json" }
      assert_equal 1, calls[0]
    end

    get job_path(job), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    doc = Nokogiri::HTML(response.body)

    # The dialog is pre-rendered, so opening it is a no-op request-wise.
    dialog = doc.at_css("#jev-popup-#{v.id}")
    refute_nil dialog, "a Jev dialog per finished proof"
    assert_match(/dominant issue/i, dialog.text,
                 "stored answers are rendered into the dialog server-side")
    assert_match(/screen explosion/i, dialog.text,
                 "and the card carries its VALUE -- jev_answer_view reads " \
                 "ans['choice'], so a fixture using 'value' renders a blank card")

    btn = doc.at_css(%(button[data-popup="jev-popup-#{v.id}"]))
    refute_nil btn
    assert_equal "1", btn["data-has-answers"],
                 "data-has-answers is what stops askJev() firing on open"
    assert_includes btn["class"].split, "has-answers"
  end

  test "a proof with no answers still asks the runner once" do
    job = job_with_candidates
    v = proof_for(job, "candidate_02.svg")
    refute v.jev_answers.present?

    counting_ask_jev do |calls|
      post ask_jev_validation_path(v, format: :json),
           headers: { "User-Agent" => MODERN_UA, "Accept" => "application/json" }
      assert_response :success
      assert_equal 1, calls[0], "a first ask is still allowed"
    end
  end

  # --- the 67/33 split and the per-proof Jev buttons -------------------------

  test "the proofs table is narrow-column compact, not the old wide one" do
    job = job_with_candidates
    proof_for(job, "candidate_01.svg")
    get job_path(job), headers: { "User-Agent" => MODERN_UA }
    doc = Nokogiri::HTML(response.body)

    heads = doc.at_css(".results-side table.proofs-tbl thead").css("th").map { |t| t.text.strip }
    assert_equal ["Preview", "Proof", "State", ""], heads,
                 "three data columns plus actions -- the column is a third of the " \
                 "width, and State is what you scan it for"
    # Advisory, Hard and the fidelity numbers all moved into the row's detail
    # popup. State stays: without it a row says nothing about where the proof got
    # to.
    %w[Advisory Hard Fidelity].each do |gone|
      refute_includes heads, gone, "#{gone} moved into the detail popup"
    end
    assert_includes heads, "State"
  end

  test "candidates sit left at 67% and the proof column right at 33%" do
    css = Rails.root.join("app/assets/stylesheets/application.css").read
         .gsub(%r{/\*.*?\*/}m, "")
    split = css[/\.results-split \{[^}]*\}/m]
    refute_nil split
    assert_match(/display: grid/, split)
    # 2fr 1fr, not 1fr 1fr -- the table is the work, the column is the action.
    assert_match(/grid-template-columns: 2fr 1fr/, split)
    assert_match(/align-items: start/, split)
    assert_match(/min-width: 0/, css[/.*\.results-main, \.results-side \{[^}]*\}/m].to_s,
                 "without min-width: 0 a wide <table> refuses to shrink")

    # The proofs table has to FIT 33%, which is not free: with auto layout it
    # measured 477px inside a 416px column and scrolled sideways.
    proofs = css[/\.proofs-tbl \{[^}]*\}/m]
    assert_match(/table-layout: fixed/, proofs)
    assert_match(/width: 100%/, proofs)
    # The prefix is load-bearing, not decoration: `table.candidates
    # td.col-thumb { width: 1% }` is (0,2,2) and beat a bare `.proofs-tbl
    # td:nth-child(n)` at (0,2,1), collapsing every column to 1%.
    assert_match(/table\.candidates\.proofs-tbl td:nth-child\(1\)/, css)
    # Actions is the 4th column, not the 5th: the Hard column was removed (its
    # number is in the row's detail popup), and these indices are positional, so
    # leaving a 5 here would position rules for a column that does not exist and
    # size the actions cell as if it were still Hard's 36px.
    assert_match(/table\.candidates\.proofs-tbl td:nth-child\(4\)/, css)
    refute_match(/table\.candidates\.proofs-tbl td:nth-child\(5\)/, css,
                 "there is no 5th column to size")
    assert_match(/table\.candidates\.proofs-tbl td:nth-child\(2\)\s*\{[^}]*text-overflow: ellipsis/m, css,
                 "the name ellipsises; max-width: 0 is what makes that bite in a fixed cell")

    small = css[/@media \(max-width: 900px\) \{\s*\.results-split \{[^}]*\}/m]
    refute_nil small, "the split must collapse on a narrow window"
  end

  test "the proofs table IS the right column, with no button in front of it" do
    job = job_with_candidates
    v = proof_for(job, "candidate_01.svg")

    get job_path(job), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    doc = Nokogiri::HTML(response.body)

    split = doc.at_css(".results-split")
    refute_nil split, "the results page is split"
    main = split.at_css(".results-main")
    side = split.at_css(".results-side")
    refute_nil main
    refute_nil side

    # Left: the candidates table.
    assert_equal 1, main.css("table.candidates").size

    # Right: the proofs table, visible, NOT behind a button. A giant Proof button
    # in a third-width column was the wrong answer twice over: it hid the proofs
    # and it was a whole column given to one control.
    assert_equal 1, side.css("table.candidates").size,
                 "the proofs table is the right column"
    assert_equal 1, side.css("table.proofs-tbl").size
    assert_equal 1, side.css("tbody tr").size, "one row per proof"
    assert_nil doc.at_css("#proofs-popup"), "the wrapper popup is gone"
    assert_equal 0, doc.css(".results-proof-btn").size,
                 "no button standing in for the table"
    assert_equal 0, doc.css("button.results-proof-btn").size
    # The candidate table lost its Palette column.
    cand_heads = main.css("thead th").map { |t| t.text.strip }
    refute_includes cand_heads, "Palette", "the Palette column is gone from the candidates table"

    # The rows carry a detail button and a Jev button.
    row = side.at_css("table.proofs-tbl tbody tr")
    refute_nil row
    assert_equal 1, row.css("button[data-popup='proof-detail-#{v.id}']").size,
                 "a detail button per proof row"
    assert_equal 1, row.css("button.jev-btn").size
  end

  test "each proof row has a detail popup holding what the narrow column drops" do
    job = job_with_candidates
    v = proof_for(job, "candidate_01.svg",
                  manifest: { "proof" => "proof_01.png", "print_pdf" => "proof_01.pdf",
                              "summary" => { "hard" => 2, "advisory" => 1 },
                              "stats" => { "dpi" => 300, "rendered_ink_colors" => 4,
                                           "static" => { "path_nodes_total" => 812 } },
                              "findings" => [ { "rule" => "COLOR_COUNT", "severity" => "hard",
                                                "layer" => "A", "detail" => "too many colours" } ] })

    get job_path(job), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    doc = Nokogiri::HTML(response.body)

    dlg = doc.at_css("#proof-detail-#{v.id}")
    refute_nil dlg, "a detail popup per proof, whatever its state"
    assert dlg.key?("hidden"), "it starts hidden (valueless attr reads as \"\")"
    txt = dlg.text
    # The columns the 33% table gave up, all present in the popup.
    assert_match(/advisory/i, txt)
    assert_match(/inks/i, txt)
    assert_match(/nodes/i, txt)
    assert_match(/dpi/i, txt)
    assert_match(/300/, txt, "the dpi VALUE, not just the label")
    assert_match(/812/, txt, "the node count")
    # The findings themselves.
    assert_match(/COLOR_COUNT/, txt)
    assert_match(/too many colours/, txt)
    # And the links.
    assert_match(/Proof PNG/, txt)
    assert_match(/Print PDF/, txt)
    assert_match(/Open proof/, txt)
  end

  test "a clean proof says so in its detail popup instead of showing nothing" do
    job = job_with_candidates
    v = proof_for(job, "candidate_02.svg",
                  manifest: { "proof" => "proof_02.png",
                              "summary" => { "hard" => 0, "advisory" => 0 },
                              "findings" => [] })
    get job_path(job), headers: { "User-Agent" => MODERN_UA }
    doc = Nokogiri::HTML(response.body)
    assert_match(/clean pass/i, doc.at_css("#proof-detail-#{v.id}").text,
                 "an empty findings list must not read as 'nothing was checked'")
  end

  test "each proof row carries its own Jev button and dialog" do
    job = job_with_candidates
    a = proof_for(job, "candidate_01.svg")
    b = proof_for(job, "candidate_02.svg", jev_answers: ANSWERS,
                                       jev_meta: { "model" => "test-model" })

    get job_path(job), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    doc = Nokogiri::HTML(response.body)
    popup = doc.at_css(".results-side")

    ids = popup.css("button.jev-btn").map { |b_| b_["data-popup"] }
    assert_equal ["jev-popup-#{a.id}", "jev-popup-#{b.id}"].sort, ids.sort,
                 "one Jev button per proof row, each opening its own dialog"

    # A dialog per FINISHED proof, and the answered one is pre-rendered.
    refute_nil doc.at_css("#jev-popup-#{a.id}")
    refute_nil doc.at_css("#jev-popup-#{b.id}")

    asked_btn = doc.at_css(%(button[data-popup="jev-popup-#{a.id}"]))
    answered_btn = doc.at_css(%(button[data-popup="jev-popup-#{b.id}"]))
    assert_equal "0", asked_btn["data-has-answers"]
    assert_equal "1", answered_btn["data-has-answers"]
    assert_includes answered_btn["class"].split, "has-answers"
    refute_includes asked_btn["class"].split, "has-answers"

    # A unique id per dialog: the old aether.js hardcoded "jev-popup" and only
    # the first of these would have been wired.
    dialog_ids = doc.css(".popup").map { |d| d["id"] }.compact
    assert_equal dialog_ids.uniq, dialog_ids, "popup ids must be unique"
    refute_includes dialog_ids, "jev-popup"
  end

  test "an unfinished proof gets no Jev button, because Jev needs a finished proof" do
    job = job_with_candidates
    pending = job.validations.create!(file: "candidate_03.svg", state: "pending")

    get job_path(job), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    doc = Nokogiri::HTML(response.body)

    assert_nil doc.at_css(%(button[data-popup="jev-popup-#{pending.id}"]))
    assert_nil doc.at_css("#jev-popup-#{pending.id}"), "and no dialog for it either"
    # A detail popup it DOES get: the state and the "not finished" wording are
    # worth showing even before the proof lands.
    refute_nil doc.at_css("#proof-detail-#{pending.id}")
  end

  test "a job with no proofs still renders the Proof button and says so" do
    job = job_with_candidates
    get job_path(job), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    doc = Nokogiri::HTML(response.body)

    assert_equal 0, doc.css("table.proofs-tbl").size
    assert_match(/No proofs/i, doc.at_css(".results-side-note").text)
  end
end
