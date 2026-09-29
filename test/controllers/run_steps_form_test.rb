require "test_helper"

# The Run Job form's SEQUENCE editor: an ordered step list in ONE job.
#
# The form-side half. What is asserted here is the markup the browser builds on
# and the help that explains it; the COMPOSITION of `spec["steps"]` happens in
# JavaScript and is exercised in a real browser (see the deploy verification),
# and the model and worker sides are covered in test/models/job_steps_test.rb and
# test/jobs/run_steps_test.rb.
class RunStepsFormTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  EXTRA_RUNNER_ENV = %w[CHOPSHOP_FLUX_HANDOFF_RUNNER].freeze

  def with_runners
    saved = {}
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| saved[k] = ENV.delete(k) }
    EXTRA_RUNNER_ENV.each { |k| saved[k] = ENV.delete(k) }
    begin
      ENV["CHOPSHOP_RUNNER_BP_URL"] = "http://bp.invalid:8796"
      ENV["CHOPSHOP_RUNNER_BP_KIND"] = "bp"
      ENV["CHOPSHOP_RUNNER_SVG_URL"] = "http://pipeline.invalid:8791"
      ENV["CHOPSHOP_RUNNER_FLUX_URL"] = "http://flux.invalid:8795"
      ENV["CHOPSHOP_RUNNER_FLUX_KIND"] = "flux"
      Job.reset_runners_cache!
      yield
    ensure
      ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| ENV.delete(k) }
      EXTRA_RUNNER_ENV.each { |k| ENV.delete(k) }
      saved.each { |k, v| ENV[k] = v }
      Job.reset_runners_cache!
    end
  end

  def login
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" },
                      headers: { "User-Agent" => MODERN_UA }
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  def form
    login
    get new_job_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  end

  test "the form carries a sequence editor, off by default" do
    with_runners do
      doc = form
      card = doc.at_css("#stepsCard")
      refute_nil card, "the sequence editor must be on the page"

      toggle = card.at_css("#seq_on")
      refute_nil toggle, "the on/off control"
      assert_nil toggle["checked"], "a job is ONE action unless asked to be a list"

      body = card.at_css("#seqBody")
      refute_nil body, "the step list's own body"
      assert body["hidden"], "and it starts hidden, so the single action is the default"

      refute_nil card.at_css("#stepsList"), "where the rows are appended"
      refute_nil card.at_css("#addStepBtn"), "the control that adds one"
      refute_nil card.at_css("#seqSummary"), "and the line that reports the order"
    end
  end

  test "the sequence editor sits INSIDE the form, where the contract is posted from" do
    # The rows write into job[spec], so the card must live inside the form or the
    # controls would compose a contract that is never posted -- the failure mode
    # that looks like nothing at all happened.
    with_runners do
      doc = form
      # Scoped to the JOB form by id, not to the first <form> on the page: the
      # layout's Log out control is a button_to, which renders a form of its own,
      # so a bare `at_css("form")` finds the logout form and the assertion then
      # reports a placement bug that is really a probe reading the wrong node.
      the_form = doc.at_css("form#new-job-form")
      refute_nil the_form, "the job form is identified by its own id"
      refute_nil the_form.at_css("#stepsCard"),
        "the sequence card must be a descendant of the form, not a sibling of it"
      refute_nil the_form.at_css("textarea[name='job[spec]']"),
        "and the contract it composes must still be a real posted field"
    end
  end

  test "the sequence's help explains the order, the runner, the input and the failure" do
    with_runners do
      doc = form
      button = doc.at_css("#stepsCard .help-btn")
      refute_nil button, "every card explains itself through a ?"
      block = doc.at_css("##{button['data-help-target']}")
      refute_nil block, "#{button['data-help-target']} must exist, or the ? opens nothing"

      terms = block.css("dt").map { |dt| dt.text.strip }
      assert_equal %w[Sequence Runner Input Hand-off When\ it\ fails], terms

      body = block.text.gsub(/\s+/, " ")
      assert_match(/in order/i, body, "the order is the instruction, so it is said")
      assert_match(/stateless/i, body,
        "and the reason the CHAIN is orchestrated here rather than by a runner")
      assert_includes body, "previous", "the hand-off declaration is named"
      assert_match(/which one it was|stops/i, body, "a mid-chain failure is described")
    end
  end

  test "the toggle's own hint says what ticking it changes" do
    with_runners do
      hint = form.at_css("#stepsCard").text.gsub(/\s+/, " ")
      assert_match(/single action/i, hint, "off is named")
      assert_match(/in\s+order|in order/i, hint, "and on is named")
      assert_match(/one job/i, hint, "and that the list is one job, not several")
    end
  end
end
