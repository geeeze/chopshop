require "test_helper"

# THE HAND-OFFS THAT USED TO 500.
#
# Three surfaces carry a payload from one page to another — /reuse (clone a
# job's spec), /json/use (a built contract) and the datasets "use this prompt"
# button — and all three put it in the SESSION, which is a 4 KB cookie. Measured
# on the live box: a blend-plot job's spec was 15,816 bytes, and the failure was
# NOT a clean 500 in the action: reuse answered 302 and Rails raised
# ActionDispatch::Cookies::CookieOverflow while committing that response's
# cookie, so the exception surfaced on a request that had already succeeded and
# the log blamed the redirect.
#
# The contract these tests pin is the SHAPE, not a size guard: the payload never
# rides in the cookie at all, so there is no length at which this fails again.
# The cookie assertions are the proof — a test that only checked "the form shows
# the spec" would pass against the old code for every spec under 4 KB, which is
# 164 of the live box's 179 jobs and exactly why this went unnoticed.
class DraftHandoffTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  # A spec larger than the cookie that has to hold it. The marker is what the
  # cookie assertions search for, so a leak is named rather than inferred from a
  # byte count.
  MARKER = "DRAFTMARKER".freeze
  PNG = "\x89PNG\r\n\x1a\n".b + ("pngbytes" * 8).b

  def big_spec
    {
      "print" => { "dpi" => 300, "notes" => ([MARKER] * 400).join(" ") },
      "documents" => (1..200).map { |i| { "id" => i, "body" => "x" * 40 } }
    }
  end

  def login!
    post login_path, params: { password: "test-password" },
                     headers: { "User-Agent" => MODERN_UA }
  end

  def with_get_file(body: PNG, status: 200)
    original = RunnerClient.method(:get_file)
    RunnerClient.define_singleton_method(:get_file, lambda { |_url, **_opts|
      { status: status, body: body }
    })
    yield
  ensure
    RunnerClient.define_singleton_method(:get_file, original)
  end

  def job_with(spec)
    # The runner label comes from the env-driven registry rather than being named
    # here: `Job.runners` is built from CHOPSHOP_RUNNER_<LABEL>_URL, so which
    # labels exist is a property of the DEPLOYMENT, and a test that hardcodes
    # "svg" passes in one environment and fails in the next. Only the spec size
    # matters to what this file tests.
    Job.create!(name: "draft-source", state: "done", source_kind: "svg",
                input_path: "/data/draft.svg", stem: "draft-source",
                runner: Job.runners.keys.first, spec: spec, comparison: { "candidates" => [] })
  end

  # The cookie this response set. Rails may emit several; the session is the one
  # whose value carries the payload, so every Set-Cookie header is examined.
  def set_cookies
    response.headers["Set-Cookie"].to_s
  end

  test "reuse hands off a spec larger than a cookie can hold" do
    login!
    job = job_with(big_spec)
    assert_operator JSON.pretty_generate(job.spec).bytesize, :>, 4096,
                    "this test is only meaningful with a spec that outgrew the cookie"

    with_get_file do
      post reuse_job_path(job, name: "source.png")
      assert_response :redirect,
                      "reuse must not fail on a large spec (pre-fix this raised CookieOverflow)"
    end

    uri = URI.parse(response.location)
    token = Rack::Utils.parse_query(uri.query)["spec_draft_token"]
    refute_nil token, "the hand-off carries a token"
    assert_match %r{/jobs/new}, uri.path

    # THE COOKIE IS THE POINT: the payload is not in it, and it is well under the
    # 4 KB ceiling whatever the spec's size.
    refute_includes set_cookies, MARKER, "the spec must not ride in the cookie"
    assert_operator set_cookies.bytesize, :<, 4096

    # …and the form still shows it, which is what the hand-off is for.
    get uri.path + "?" + uri.query
    assert_response :success
    assert_includes response.body, MARKER, "the spec reaches the form via the draft"
    cleanup_test_uploads(/^upload_/)
  end

  test "a reused spec is the SOURCE JOB's own spec, not a stale draft" do
    login!
    first = job_with("print" => { "dpi" => 111, "marker" => "FIRSTSPECDRAFT" })
    second = job_with("print" => { "dpi" => 222, "marker" => "SECONDSPECDRAFT" })

    with_get_file do
      post reuse_job_path(first, name: "source.png")
    end
    uri = URI.parse(response.location)
    with_get_file { post reuse_job_path(second, name: "source.png") }
    second_uri = URI.parse(response.location)

    get second_uri.path + "?" + second_uri.query
    assert_includes response.body, "SECONDSPECDRAFT"
    refute_includes response.body, "FIRSTSPECDRAFT",
                    "the newest hand-off wins; a draft is read by its own token"
    refute_equal Rack::Utils.parse_query(uri.query)["spec_draft_token"],
                 Rack::Utils.parse_query(second_uri.query)["spec_draft_token"]
    cleanup_test_uploads(/^upload_/)
  end

  test "an unknown or foreign token renders the form with no draft, never a 500" do
    login!
    get new_job_path(spec_draft_token: "not-a-real-token")
    assert_response :success
    assert_includes response.body, "run-contract", "the form is the form"

    # A token belonging to ANOTHER workspace resolves to nothing: a token is a
    # reference, not a capability (SessionDraft is owner-scoped).
    foreign = SessionDraft.create!(owner: "someone-else", kind: SessionDraft::SPEC,
                                   body: '{"print":{"marker":"OTHERSWORKSPACE"}}',
                                   token: "foreign-token")
    get new_job_path(spec_draft_token: foreign.token)
    assert_response :success
    refute_includes response.body, "OTHERSWORKSPACE"
  end

  test "/json/use carries a built contract out of the cookie" do
    login!
    contract = { "print" => { "dpi" => 300, "notes" => ([MARKER] * 400).join(" ") },
                 "documents" => (1..200).map { |i| { "id" => i, "body" => "y" * 40 } } }
    body = JSON.generate(contract)
    assert_operator body.bytesize, :>, 4096

    post use_json_path, params: { spec: body }
    assert_response :redirect
    refute_includes set_cookies, MARKER, "the contract must not ride in the cookie"
    assert_operator set_cookies.bytesize, :<, 4096

    get response.location
    assert_response :success
    assert_includes response.body, MARKER
  end

  test "a prompt drawn from the library rides in a draft, not the cookie" do
    login!
    long = "a very long prompt " * 300
    source = PromptSource.create!(dataset: "diffusiondb", prompt: long,
                                  part: "part-000001", topic: "art",
                                  phrase_root: "a very long")
    post use_datasets_path(id: source.id)
    assert_response :redirect
    refute_includes set_cookies, "a very long prompt"
    assert_operator set_cookies.bytesize, :<, 4096

    get response.location
    assert_response :success
    assert_includes response.body, "Carried in from the DATASETS library"
    # provenance is the dataset's attribution plus the part, so assert the value
    # the record computes rather than a spelling this test invents.
    assert_includes response.body, ERB::Util.html_escape(source.provenance)
  end

  test "the session cookie holds nothing but the user id" do
    login!
    cookie = set_cookies
    refute_includes cookie, "spec_draft"
    refute_includes cookie, "prompt_draft"
    # Whatever else grows in the session, a payload must never be the reason a
    # request fails; this is the size that has to stay small.
    assert_operator cookie.bytesize, :<, 1024
  end
end
