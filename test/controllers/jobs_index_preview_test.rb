require "test_helper"

# What the PREVIEW cell of the Jobs list (/jobs) shows, per kind of run.
#
# The thumbnail is the run's RESULT, not the raster it started from: when a run
# has candidates, the row previews the TOP one — the comparison's list arrives
# ranked, so the first entry is the candidate the operator is being asked to
# pick, and that is what a row "waiting for proofs" should show. Only a run with
# NO candidates falls back to the drawing/geometry it ran on: the first
# generated variation for a flux job, the drawn SVG for a plot job, the runner's
# source.png for a pipeline job before its sweep lands.
#
# Two routes serve those files, so the fallback is a TWO-sided decision and this
# file asserts both sides against the SERVED page:
#
#   a candidate            -> the runner's file proxy (file_job_path)
#   flux raster variation  -> storage/uploads (upload_preview_jobs_path)
#   plot SVG               -> storage/uploads (upload_preview_jobs_path)
#   pipeline source.png    -> the runner's file proxy (file_job_path)
#
# The trap: a candidate filename sent at upload_preview 404s, and the tile's own
# onerror then removes the image — a blank cell on a live page with every
# model-level assertion still green. So the routing is asserted, not just the
# filename: a flux TRACE job carries candidates AND is a flux job, which is the
# one combination where the two decisions disagree.
class JobsIndexPreviewTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  TOP = "candidate_01.svg".freeze
  SECOND = "candidate_04.svg".freeze
  RASTER = "flux_raster_aa11.png".freeze
  PLOT_SVG = "plot_a1b2c3.svg".freeze
  SOURCE = "source.png".freeze

  # Hermetic: every runner variable is cleared, then the two non-pipeline kinds
  # are configured. `mock` is always registered (Job::RUNNER_DEFAULTS), so a
  # pipeline job needs no env of its own and the deployment's real runners can
  # never make these assertions true for the wrong reason.
  def with_runners
    saved = {}
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| saved[k] = ENV.delete(k) }
    begin
      ENV["CHOPSHOP_RUNNER_FLUX_URL"] = "http://generator.invalid:8795"
      ENV["CHOPSHOP_RUNNER_FLUX_KIND"] = "flux"
      ENV["CHOPSHOP_RUNNER_PLOT_URL"] = "http://plot.invalid:8796"
      ENV["CHOPSHOP_RUNNER_PLOT_KIND"] = "plot"
      Job.reset_runners_cache!
      yield
    ensure
      ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| ENV.delete(k) }
      saved.each { |k, v| ENV[k] = v }
      Job.reset_runners_cache!
    end
  end

  def candidates(*files)
    files.map do |file|
      { "file" => file, "sweep" => { "preset" => "bw" },
        "layer_a" => { "status" => "pass" }, "layer_b" => { "status" => "pass" },
        "hard" => 0, "advisory" => 0, "fidelity" => {}, "passed" => true }
    end
  end

  def pipeline_job(name, files: [])
    Job.create!(name: name, state: "done", source_kind: "raster", runner: "mock",
                input_path: "/data/x.png", stem: name, spec: {},
                comparison: { "candidates" => candidates(*files) })
  end

  def flux_job(name, mode:, files: [])
    spec = { "flux" => { "mode" => mode, "prompt" => "a lighthouse at dusk",
                         "images" => 1, "rendered" => { "images" => [ { "file" => RASTER } ] } } }
    Job.create!(name: name, state: "done", source_kind: "raster", runner: "flux",
                input_path: "storage/uploads/#{RASTER}", stem: name, spec: spec,
                comparison: { "candidates" => candidates(*files) })
  end

  def plot_job(name)
    spec = { "plot" => { "op" => "generate",
                         "doc" => { "canvas" => { "width" => 10, "height" => 10 },
                                    "elements" => [] },
                         "rendered" => { "file" => PLOT_SVG, "op" => "generate" } } }
    Job.create!(name: name, state: "done", source_kind: "raster", runner: "plot",
                input_path: "", stem: name, spec: spec)
  end

  def index_doc
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    get jobs_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  # The row's own preview image, found by the accessible name the view writes
  # for it — so the assertion cannot pass on some other row's thumbnail.
  def preview_src(doc, job)
    img = doc.at_css(%(img[alt="Preview for #{job.name}"]))
    refute_nil img, "#{job.name}: the preview cell rendered no image"
    img["src"]
  end

  test "a pipeline job with candidates previews its TOP candidate through the file proxy" do
    with_runners do
      job = pipeline_job("swept", files: [ TOP, SECOND ])
      src = preview_src(index_doc, job)

      assert_equal file_job_path(job, name: TOP), src,
        "the first candidate in the ranked list is the run's result"
      refute_includes src, "candidate_04",
        "and not just any candidate -- the top one"
      refute_includes src, upload_preview_jobs_path(name: TOP),
        "a candidate lives on the runner, never in storage/uploads"
    end
  end

  test "a pipeline job with no candidates yet falls back to source.png" do
    with_runners do
      job = pipeline_job("prepping")
      assert_equal file_job_path(job, name: SOURCE), preview_src(index_doc, job),
        "before the sweep there is no result to show, so the raster it was fed stands in"
    end
  end

  test "a flux TRACE job previews its top candidate, from the runner" do
    with_runners do
      job = flux_job("generated", mode: "trace", files: [ TOP, SECOND ])
      src = preview_src(index_doc, job)

      assert_equal file_job_path(job, name: TOP), src,
        "a traced generation's result is the candidate, exactly as a pipeline job's is"
      refute_includes src, upload_preview_jobs_path(name: TOP),
        "the raster's route must NOT carry a candidate filename: the two " \
        "decisions disagree on this one kind of job, which is what this pins"
    end
  end

  test "a flux RASTER-ONLY job previews its generated variation, from uploads" do
    with_runners do
      job = flux_job("rasterized", mode: "raster")
      src = preview_src(index_doc, job)

      assert_equal upload_preview_jobs_path(name: RASTER), src,
        "there are no candidates to prefer, so the raster IS the result"
      refute_equal file_job_path(job, name: RASTER), src,
        "and it is served from storage/uploads, not proxied off a runner"
    end
  end

  test "a plot job previews its drawn SVG, from uploads" do
    with_runners do
      job = plot_job("chart")
      src = preview_src(index_doc, job)

      assert_equal upload_preview_jobs_path(name: PLOT_SVG), src,
        "a plot job never has candidates: the drawing is the deliverable"
      refute_includes src, "source.png", "and it is not the pipeline's raster"
    end
  end

  test "the model answers the filename and its route together, per kind" do
    with_runners do
      swept = pipeline_job("m1", files: [ TOP, SECOND ])
      bare = pipeline_job("m2")
      traced = flux_job("m3", mode: "trace", files: [ TOP ])
      raster = flux_job("m4", mode: "raster")
      chart = plot_job("m5")

      assert_equal [ TOP, "source.png", TOP, RASTER, PLOT_SVG ],
                   [ swept, bare, traced, raster, chart ].map(&:preview_file)

      # The route flag must agree with the filename in EVERY case: a candidate
      # is a runner file (`false`), the flux variation and the plot SVG are
      # uploads (`true`), and source.png is a runner file (`false`).
      assert_equal [ false, false, false, true, true ],
                   [ swept, bare, traced, raster, chart ].map(&:preview_from_upload?)
    end
  end

  test "a job with nothing to show renders the placeholder, not a broken image" do
    with_runners do
      # A queued plot job has no drawn SVG and no candidates: the cell must stay
      # empty so it degrades to the matte-grey scissor placeholder.
      job = Job.create!(name: "pending-chart", state: "queued", source_kind: "raster",
                        runner: "plot", input_path: "", stem: "pending-chart",
                        spec: { "plot" => { "op" => "generate",
                                            "doc" => { "canvas" => { "width" => 10,
                                                                     "height" => 10 },
                                                       "elements" => [] } } })
      assert_nil job.preview_file
      assert_nil index_doc.at_css(%(img[alt="Preview for #{job.name}"]))
    end
  end

  test "a malformed comparison is not a candidate" do
    with_runners do
      # The comparison is runner-supplied JSON; a job stored before candidates
      # existed, or one whose sweep returned junk, must still fall back rather
      # than raise on the list page.
      [ nil, "not a hash", { "candidates" => "nope" }, { "candidates" => [] },
       { "candidates" => [ { "sweep" => {} } ] }, { "candidates" => [ "candidate_01.svg" ] } ].each do |raw|
        job = pipeline_job("junk-#{raw.inspect.hash.abs}", files: [])
        job.update!(comparison: raw)
        assert_nil job.reload.top_candidate_file, "junk comparison: #{raw.inspect}"
        assert_equal SOURCE, job.preview_file
        refute job.preview_from_upload?, "and a pipeline job's raster is a runner file"
      end
    end
  end
end
