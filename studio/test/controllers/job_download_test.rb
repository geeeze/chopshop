require "test_helper"

# DOWNLOADING A JOB -- and the fallback for a job the STUDIO holds itself.
#
# A pipeline job's archive is the runner's, and #download proxies it. A FLUX
# job's is the studio's own provenance bundle (FluxArchive; see
# flux_provenance_test). But a BP job -- and a legacy plot or blender one --
# carries NO runner job id: the studio drew it in-process, wrote the artefact
# into storage/uploads and recorded its name in the job's own spec.
#
# Before this, #download proxied the runner's archive endpoint for such a job
# anyway, so every bp Download answered "Archive unavailable (runner 404)" and
# 302'd back to the project -- while the Download button still offered it.
#
# The fallback is keyed on the MISSING RUNNER JOB, not on the proxy failing: for
# a job that DID dispatch, a studio-side bundle would be a quietly partial
# download (no candidates, no proofs). The last two tests pin that line.
class JobDownloadTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  SVG = '<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4">' \
        '<rect width="4" height="4"/></svg>'.freeze
  # Stands in for a rendered frame: the bundle must carry real bytes, and a
  # byte-count stand-in would not prove the frame travelled.
  FRAME = "PNGDATA-0123456789".b.freeze
  # Stands in for the runner's own 7z.
  RUNNER_ARCHIVE = "7z\u001c\"the runner's own archive\"".b.freeze

  GEOMETRY = { "type" => "geometry", "elements" => [{ "kind" => "box" }] }.freeze

  # The suite's own runner-env harness (same shape as job_page_bp_output_test):
  # URLs and KINDS are separate maps, and the cache reset is what makes them
  # take effect. `mock` is always registered, so the pipeline jobs below need
  # no line of their own.
  def with_runners(urls:, kinds:)
    saved = {}
    (urls.keys + kinds.keys).each { |k| saved[k] = ENV[k] }
    begin
      urls.each { |k, v| ENV[k] = v }
      kinds.each { |k, v| ENV[k] = v }
      Job.reset_runners_cache!
      yield
    ensure
      saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
      Job.reset_runners_cache!
    end
  end

  def with_bp_kind(&block)
    with_runners(urls: { "CHOPSHOP_RUNNER_DLBP_URL" => "http://bp.invalid:8796" },
                 kinds: { "CHOPSHOP_RUNNER_DLBP_KIND" => "bp" }, &block)
  end

  def login!
    post login_path, params: { password: "test-password" },
                     headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  end

  # A real file in storage/uploads, so the bundle ships real bytes. Removed by
  # snapshot diff in cleanup_test_uploads -- never by a bare prefix glob, which
  # is how a suite run once deleted a live job's bp drawings.
  def write_artifact(name, bytes = SVG)
    uploads_dir.mkpath
    uploads_dir.join(name).binwrite(bytes)
    name
  end

  # A bp job as the studio stores one after a draw: `rendered` names the
  # artefact, and there is no runner job -- the studio drew it itself.
  def bp_job(op:, rendered:, name: "bp-dl", doc: nil, project: nil)
    doc ||= GEOMETRY
    Job.create!(name: name, state: "done", source_kind: "raster",
                input_path: "", stem: name, runner: "dlbp", project: project,
                spec: { "bp" => { "op" => op, "doc" => doc, "rendered" => rendered } })
  end

  def assert_7z(body)
    assert_operator body.bytesize, :>, 0, "the bundle is not empty"
    assert_equal "application/x-7z-compressed", response.media_type
    unpack_7z(body)
  end

  # --- the fallback: a job the studio holds -------------------------------

  test "a bp job with no runner job downloads the studio's 7z of its artefact" do
    with_bp_kind do
      login!
      file = write_artifact("test_dl_bp_#{SecureRandom.hex(4)}.svg")
      job = bp_job(op: "digest", name: "bp-dl-svg",
                   rendered: { "file" => file, "op" => "digest",
                               "content_type" => "image/svg+xml" })
      assert job.bp?, "the job's kind must be bp for this to be the bug's job"
      assert_nil job.runner_job_id, "a bp job never dispatches: there is no runner job"

      get download_job_path(job), headers: { "User-Agent" => MODERN_UA }
      assert_response :success
      assert_includes response.headers["Content-Disposition"].to_s, "bp-dl-svg.7z"

      names, files = assert_7z(response.body)
      assert_includes names, "job.json"
      assert_includes names, file, "the drawn SVG is in the bundle, under its own name"
      assert_equal SVG, files[file], "the artefact travelled byte for byte"

      # The archive is readable on its own: the ask AND the answer ride in it.
      manifest = JSON.parse(files["job.json"])
      assert_equal job.id, manifest.dig("job", "id")
      assert_equal "bp-dl-svg", manifest.dig("job", "stem")
      assert_equal "dlbp", manifest.dig("job", "runner")
      assert_nil manifest.dig("job", "runner_job_id"), "the record says why there was no runner"
      assert_equal "digest", manifest.dig("spec", "bp", "op")
      assert_equal file, manifest.dig("spec", "bp", "rendered", "file")
      assert_equal [ file ], manifest["artifacts"]
      cleanup_test_uploads(/\Atest_dl_/)
    end
  end

  test "a legacy plot job downloads the SVG the studio drew" do
    with_runners(urls: { "CHOPSHOP_RUNNER_DLPLOT_URL" => "http://plot.invalid:8797" },
                 kinds: { "CHOPSHOP_RUNNER_DLPLOT_KIND" => "plot" }) do
      login!
      file = write_artifact("test_dl_plot_#{SecureRandom.hex(4)}.svg")
      job = Job.create!(name: "plot-dl", state: "done", source_kind: "raster",
                        input_path: "", stem: "plot-dl", runner: "dlplot",
                        spec: { "plot" => { "op" => "generate", "doc" => GEOMETRY,
                                            "rendered" => { "file" => file, "op" => "generate" } } })

      get download_job_path(job), headers: { "User-Agent" => MODERN_UA }
      assert_response :success

      names, files = assert_7z(response.body)
      assert_includes names, file
      assert_equal SVG, files[file]
      assert_equal "generate", JSON.parse(files["job.json"]).dig("spec", "plot", "op")
      cleanup_test_uploads(/\Atest_dl_/)
    end
  end

  test "a multi-view blender job downloads every frame it stored" do
    with_bp_kind do
      login!
      frames = 3.times.map { |i| write_artifact("test_dl_blend_#{i}_#{SecureRandom.hex(3)}.png", "#{FRAME}#{i}") }
      job = bp_job(op: "blender", name: "bp-dl-blender",
                   rendered: { "file" => frames.first, "files" => frames,
                               "op" => "blender", "views" => 3,
                               "engine" => "workbench" })

      get download_job_path(job), headers: { "User-Agent" => MODERN_UA }
      assert_response :success

      names, files = assert_7z(response.body)
      frames.each_with_index do |f, i|
        assert_includes names, f, "view #{i + 1} of 3 is in the bundle"
        assert_equal "#{FRAME}#{i}", files[f]
      end
      assert_equal frames, JSON.parse(files["job.json"])["artifacts"]
      cleanup_test_uploads(/\Atest_dl_/)
    end
  end

  # --- the runner path is untouched ---------------------------------------

  test "a job with a runner job still proxies the runner's archive, byte for byte" do
    with_bp_kind do
      login!
      job = Job.create!(name: "traced-dl", state: "done", source_kind: "raster",
                        input_path: "/data/x.png", stem: "traced-dl", runner: "mock",
                        runner_job_id: "rj-464")
      asked = []
      original = RunnerClient.method(:get_file)
      RunnerClient.define_singleton_method(:get_file) do |url, **_options|
        asked << url
        { status: 200, body: RUNNER_ARCHIVE, content_type: "application/x-7z-compressed" }
      end
      begin
        get download_job_path(job), headers: { "User-Agent" => MODERN_UA }
      ensure
        RunnerClient.define_singleton_method(:get_file, original)
      end

      assert_response :success
      assert_equal [ job.archive_url ], asked, "the runner's archive endpoint is what was read"
      assert_equal RUNNER_ARCHIVE, response.body
    end
  end

  test "a runner-backed job whose runner has no archive is still refused, not half-bundled" do
    with_bp_kind do
      login!
      # A job that DID dispatch, and also happens to name a studio artefact: the
      # fallback must NOT rescue it into a partial bundle with no candidates.
      file = write_artifact("test_dl_partial_#{SecureRandom.hex(4)}.svg")
      job = Job.create!(name: "traced-partial", state: "done", source_kind: "raster",
                        input_path: "/data/x.png", stem: "traced-partial", runner: "mock",
                        runner_job_id: "rj-465",
                        spec: { "bp" => { "op" => "digest", "doc" => GEOMETRY,
                                          "rendered" => { "file" => file } } })

      original = RunnerClient.method(:get_file)
      RunnerClient.define_singleton_method(:get_file) { |*_a, **_k| { status: 404, body: nil } }
      begin
        get download_job_path(job), headers: { "User-Agent" => MODERN_UA }
      ensure
        RunnerClient.define_singleton_method(:get_file, original)
      end

      assert_response :redirect
      assert_match(/Archive unavailable \(runner 404\)/, flash[:alert].to_s)
      cleanup_test_uploads(/\Atest_dl_/)
    end
  end

  # --- a job with nothing to archive is honest about it --------------------

  test "a job with no artefact anywhere is refused, and is not offered a button" do
    with_bp_kind do
      login!
      # A bp job that never produced a drawing: no rendered file, no runner job.
      job = Job.create!(name: "bp-dl-empty", state: "done", source_kind: "raster",
                        input_path: "", stem: "bp-dl-empty", runner: "dlbp",
                        project: workspace,
                        spec: { "bp" => { "op" => "tree", "doc" => GEOMETRY } })
      assert_empty job.studio_artifacts
      refute job.downloadable?, "a run that can produce no archive is not downloadable"

      get download_job_path(job), headers: { "User-Agent" => MODERN_UA }
      assert_response :redirect
      assert_match(/Archive failed/, flash[:alert].to_s,
                   "the refusal names the failure rather than redirecting silently")

      # And the list does not offer what the action cannot serve.
      d = list_doc
      row = d.css("tr").find { |r| r.text.include?(job.name) }
      refute_nil row, "the row is on the list"
      assert_nil row.at_css("a.cs-job-download"),
        "no download button for a run with nothing to archive"
      refute_nil row.at_css(".cs-job-download-none"),
        "and the muted mark is in its place, saying why"
      cleanup_test_uploads(/\Atest_dl_/)
    end
  end

  test "a bp job whose artefact is gone from storage/uploads is not offered a button" do
    # The live situation: the job's own record names a file that is no longer
    # there (a suite-run cleanup once wiped every bp drawing on the box). The
    # record is not evidence the artefact is on disk, so the studio holds
    # nothing to bundle.
    with_bp_kind do
      login!
      missing = "test_dl_never_written_#{SecureRandom.hex(4)}.svg"
      job = bp_job(op: "digest", name: "bp-dl-gone",
                   rendered: { "file" => missing },
                   project: workspace)
      assert_equal missing, job.bp_output_file, "the job's own record names one artefact"
      assert_empty job.studio_artifacts, "but the studio does not hold it"
      refute job.downloadable?, "the button is hidden when the artefact is not there"

      d = list_doc
      row = d.css("tr").find { |r| r.text.include?(job.name) }
      assert_nil row.at_css("a.cs-job-download")
      refute_nil row.at_css(".cs-job-download-none")
      cleanup_test_uploads(/\Atest_dl_/)
    end
  end

  private

  # The served jobs list: the project workspace (projects#show), which renders
  # jobs/_row and jobs/_card -- the same page jobs_grid_test reads.
  def list_doc
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    get project_path(workspace), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  def workspace
    @workspace ||= Project.create!(name: "dl-workspace", is_test: true)
  end
end
