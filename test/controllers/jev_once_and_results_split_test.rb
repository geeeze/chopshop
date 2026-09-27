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

    small = css[/@media \(max-width: 900px\) \{\s*\.results-split \{[^}]*\}/m]
    refute_nil small, "the split must collapse on a narrow window"
  end

  test "the proofs table is in a popup behind the Proof button, not on the page" do
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

    # The candidates table is the left column.
    assert_equal 1, main.css("table.candidates").size, "the candidate table lives left"

    # The Proof button is the right column's control.
    btn = side.at_css("button.results-proof-btn")
    refute_nil btn, "the Proof button is in the right column"
    assert_equal "Proof", btn.text.strip
    assert_equal "proofs-popup", btn["data-popup"]
    # Accessible name must contain the visible label (WCAG 2.5.3).
    assert_includes btn["aria-label"].to_s, "Proof"

    popup = doc.at_css("#proofs-popup")
    refute_nil popup, "the proofs table moved into a popup"
    assert_equal 1, popup.css("table.candidates").size, "the proof rows are in the popup"
    assert_equal 1, popup.css("tr.rowlink").size

    # And it is NOT in the page body any more.
    body_tables = doc.css("main .results-split ~ table.candidates").size
    assert_equal 0, body_tables, "no stray full-width proofs table left in the body"
  end

  test "each proof row carries its own Jev button and dialog" do
    job = job_with_candidates
    a = proof_for(job, "candidate_01.svg")
    b = proof_for(job, "candidate_02.svg", jev_answers: ANSWERS,
                                       jev_meta: { "model" => "test-model" })

    get job_path(job), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    doc = Nokogiri::HTML(response.body)
    popup = doc.at_css("#proofs-popup")

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
    refute_nil doc.at_css("button.results-proof-btn"), "the Proof button still opens"
  end

  test "a job with no proofs still renders the Proof button and says so" do
    job = job_with_candidates
    get job_path(job), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    doc = Nokogiri::HTML(response.body)

    assert_equal 1, doc.css("button.results-proof-btn").size
    assert_match(/No proofs/i, doc.at_css(".results-side-note").text)
    popup = doc.at_css("#proofs-popup")
    refute_nil popup
    assert_match(/No proofs/i, popup.text)
  end
end
