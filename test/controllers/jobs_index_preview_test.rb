require "test_helper"

# What the PREVIEW cell of the Jobs list (/jobs) shows, per kind of run.
#
# The thumbnail is the run's COLOUR SOURCE by default -- the raster the sweep
# was fed, published by the runner under the stable name `source.png` beside its
# inverted twin -- and the PROOF PNG once a pick has been proved: the proof is
# then the run's result, and the row should be recognised by it. The top
# candidate is deliberately NOT the default any more.
#
# Two routes serve those files, so the choice is a TWO-sided decision and this
# file asserts both sides against the SERVED page:
#
#   a proof PNG            -> the runner's file proxy (file_job_path)
#   pipeline source.png    -> the runner's file proxy (file_job_path)
#   flux raster-only image -> storage/uploads (upload_preview_jobs_path)
#   plot SVG               -> storage/uploads (upload_preview_jobs_path)
#
# The trap: a runner filename sent at upload_preview 404s, and the tile's own
# onerror then removes the image -- a blank cell on a live page with every
# model-level assertion still green. So the routing is asserted, not just the
# filename: a flux TRACE job is a flux job whose source lives on the runner,
# which is the one combination where the two decisions disagree.
class JobsIndexPreviewTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  TOP = "candidate_01.svg".freeze
  SECOND = "candidate_04.svg".freeze
  RASTER = "flux_raster_aa11.png".freeze
  PLOT_SVG = "plot_a1b2c3.svg".freeze
  SOURCE = "source.png".freeze
  PROOF = "proof_01.png".freeze

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

  def pipeline_job(name, files: [], runner_job_id: nil)
    Job.create!(name: name, state: "done", source_kind: "raster", runner: "mock",
                input_path: "/data/x.png", stem: name, spec: {},
                runner_job_id: runner_job_id,
                comparison: { "candidates" => candidates(*files) })
  end

  def flux_job(name, mode:, files: [], runner_job_id: nil)
    spec = { "flux" => { "mode" => mode, "prompt" => "a lighthouse at dusk",
                         "images" => 1, "rendered" => { "images" => [ { "file" => RASTER } ] } } }
    Job.create!(name: name, state: "done", source_kind: "raster", runner: "flux",
                input_path: "storage/uploads/#{RASTER}", stem: name, spec: spec,
                runner_job_id: runner_job_id,
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

  # A proof the operator has already run: the state the row reacts to.
  def prove!(job, state: "done", proof: PROOF)
    job.validations.create!(file: job.top_candidate_file || "candidate_01.svg",
                            state: state,
                            manifest: proof ? { "proof" => proof, "print_pdf" => "proof_01.pdf" } : nil)
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

  test "a pipeline job previews its COLOUR SOURCE, not its top candidate" do
    with_runners do
      job = pipeline_job("swept", files: [ TOP, SECOND ])
      src = preview_src(index_doc, job)

      assert_equal file_job_path(job, name: SOURCE), src,
        "the default display is the raster the sweep was fed"
      refute_includes src, TOP,
        "the top candidate is no longer what the row shows"
      refute_includes src, SECOND
      refute_includes src, upload_preview_jobs_path(name: SOURCE),
        "source.png lives on the runner, never in storage/uploads"
    end
  end

  test "a pipeline job with no candidates yet still previews source.png" do
    with_runners do
      job = pipeline_job("prepping")
      assert_equal file_job_path(job, name: SOURCE), preview_src(index_doc, job),
        "one rule for the colour source, swept or not -- it does not flip with the sweep"
    end
  end

  test "a FINISHED proof becomes the row's preview" do
    with_runners do
      job = pipeline_job("proved", files: [ TOP ])
      prove!(job)

      src = preview_src(index_doc, job)
      assert_equal file_job_path(job, name: PROOF), src,
        "once a pick is proved, the proof IS the run's result"
      refute_includes src, SOURCE, "and it supersedes the colour source"
      refute job.preview_from_upload?, "a proof PNG comes off the runner"
    end
  end

  test "a proof that has not finished does NOT take over the preview" do
    with_runners do
      %w[pending running error].each do |state|
        job = pipeline_job("unproved-#{state}", files: [ TOP ])
        prove!(job, state: state)
        assert_equal SOURCE, job.reload.preview_file,
          "#{state}: only a DONE proof is a delivered result"
      end
    end
  end

  test "a manifest with no render does not displace the colour source" do
    with_runners do
      job = pipeline_job("empty-manifest", files: [ TOP ])
      prove!(job, proof: nil)
      assert_equal SOURCE, job.reload.preview_file,
        "a manifest that names no proof has nothing to show"
    end
  end

  test "a flux TRACE job previews its colour source, from the runner" do
    with_runners do
      job = flux_job("generated", mode: "trace", files: [ TOP, SECOND ],
                     runner_job_id: "rj-1")
      src = preview_src(index_doc, job)

      assert_equal file_job_path(job, name: SOURCE), src,
        "a traced generation's raster is published by its pipeline runner"
      refute_includes src, upload_preview_jobs_path(name: SOURCE),
        "the raster's route must NOT carry a runner filename: the two " \
        "decisions disagree on this one kind of job, which is what this pins"
    end
  end

  test "a flux RASTER-ONLY job previews its generated variation, from uploads" do
    with_runners do
      job = flux_job("rasterized", mode: "raster")
      src = preview_src(index_doc, job)

      assert_equal upload_preview_jobs_path(name: RASTER), src,
        "there is no raster behind it to show, so the generation IS the run's source"
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
      traced = flux_job("m3", mode: "trace", files: [ TOP ], runner_job_id: "rj-2")
      raster = flux_job("m4", mode: "raster")
      chart = plot_job("m5")
      proved = pipeline_job("m6", files: [ TOP ])
      prove!(proved)

      assert_equal [ "source.png", "source.png", "source.png", RASTER, PLOT_SVG, PROOF ],
                   [ swept, bare, traced, raster, chart, proved ].map(&:preview_file)

      # The route flag must agree with the filename in EVERY case: a proof and
      # source.png are runner files (`false`), the flux variation and the plot
      # SVG are uploads (`true`).
      assert_equal [ false, false, false, true, true, false ],
                   [ swept, bare, traced, raster, chart, proved ].map(&:preview_from_upload?)
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
                                                                     "height" => 10 } } } })
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
