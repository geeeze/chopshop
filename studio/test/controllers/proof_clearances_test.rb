require "test_helper"

# A gate the RUN disarmed must not read as a gate that PASSED.
#
# The manifest only records what went wrong, so the proof page states its
# clearances positively (the "this proof clears:" checklist). Two Layer A gates
# can be turned off by the run's OWN spec -- `geometry.allow_gradients` makes the
# pipeline return before it looks for a gradient, `geometry.allow_raster_embed`
# makes it skip the raster scan -- and a disarmed gate produces no finding
# either. Read as "the rule is absent from findings", both therefore used to
# appear as clearances for checks that never ran: the page claimed "no gradient
# declaration and no url(#…) paint server in the source" for a job whose own
# spec told the validator not to look.
#
# The unit rule lives in ApplicationHelper#cleared_checks (pinned in
# jobs_list_proof_test.rb). What THIS file pins is the part a helper test cannot
# reach: the run's spec has to be handed to that helper by each of its two
# callers -- the proof page and the job results popup -- because a caller that
# forgot to pass it would leave the page reading as unknown/not-cleared at best.
class ProofClearancesTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def sign_in
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  def clean_manifest(allow_gradients: false)
    static = { "paths" => 4, "paths_over_node_limit" => 0,
               "palette_conformance" => "all colours on palette" }
    # `geometry.allow_raster_embed` is deliberately absent from stats: the
    # pipeline records allow_gradients but still does not record this one, which
    # is exactly why the run's spec has to be read for it.
    static["allow_gradients"] = allow_gradients
    { "proof" => "proof_01.png", "print_pdf" => "proof_01.pdf",
      "summary" => { "hard" => 0, "advisory" => 0 },
      "stats" => { "static" => static },
      "findings" => [] }
  end

  def job_with_proof(name:, spec:, comparison: false, allow_gradients: false)
    job = Job.create!(name: name, state: "done", source_kind: "svg",
                      input_path: "/data/#{name}.svg", stem: name,
                      spec: spec, runner: "mock")
    job.candidates.create!(file: "candidate_01.svg", passed: true, hard: 0, advisory: 0)
    if comparison
      # The results section (and the proof popups in it) only renders for a done
      # job that carries a comparison, so the popup assertions need one.
      job.update!(comparison: { "candidates" => [{ "file" => "candidate_01.svg",
                                                   "hard" => 0, "advisory" => 0,
                                                   "passed" => true }] })
    end
    [job, job.validations.create!(file: "candidate_01.svg", state: "done",
                                  manifest: clean_manifest(allow_gradients: allow_gradients))]
  end

  def doc
    Nokogiri::HTML(response.body)
  end

  def clearances_in(node)
    node.css(".cleared-list .cleared-label").map { |el| el.text.strip }
  end

  def skipped_in(node)
    node.at_css(".cleared-skipped")&.text.to_s
  end

  test "the proof page clears an ARMED gate and refuses to clear a DISARMED one" do
    # Armed: the spec says nothing, and the pipeline's own default is off, so
    # both gates ran and the clearances are earned.
    _armed_job, armed = job_with_proof(name: "armed", spec: { "print_method" => "screen_print" })
    # Disarmed: the run's own spec turns both checks off, and the manifest records
    # the gradient flag the way the pipeline writes it -- true.
    _off_job, disarmed = job_with_proof(
      name: "disarmed", allow_gradients: true,
      spec: { "geometry" => { "allow_gradients" => true, "allow_raster_embed" => true } }
    )

    sign_in
    get validation_path(armed), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    assert_includes clearances_in(doc), "Gradients"
    assert_includes clearances_in(doc), "Raster embeds"
    refute_includes skipped_in(doc), "allow_gradients",
      "a gate that ran and passed is not a 'not run' statement"

    get validation_path(disarmed), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    labels = clearances_in(doc)
    refute_includes labels, "Gradients",
      "geometry.allow_gradients true returns before the gradient check runs"
    refute_includes labels, "Raster embeds",
      "geometry.allow_raster_embed true skips the raster check entirely"

    # Not silently dropped either: an unchecked gate is reported as not run, and
    # named by the flag that disarmed it, so the operator can see why.
    skipped = skipped_in(doc)
    assert_includes skipped, "allow_gradients"
    assert_includes skipped, "allow_raster_embed"
  end

  test "the job results popup carries the same rule through proof_detail" do
    job, proof = job_with_proof(
      name: "popup", comparison: true,
      spec: { "geometry" => { "allow_raster_embed" => true } }
    )

    sign_in
    get job_path(job), headers: { "User-Agent" => MODERN_UA }
    assert_response :success

    popup = doc.at_css("#proof-detail-#{proof.id}")
    refute_nil popup, "the results page renders the proof popup for each proof"
    labels = clearances_in(popup)
    refute_includes labels, "Raster embeds",
      "the popup reads the SAME checklist, so it cannot over-claim either"
    assert_includes labels, "Gradients",
      "and a gate this run did NOT disarm still reads as cleared"
    assert_includes skipped_in(popup), "allow_raster_embed"
  end
end
