require "test_helper"

# THE JOB PAGE FOR A bp RUN — the page that used to be blank.
#
# The bug: a bp job stores its artifact under spec.bp.rendered, and the source
# stack only ever asked for the two LEGACY accessors (plot_file reads
# spec.plot.rendered, blender_file reads spec.blender.*). Since the new-job form
# offers only bp (plot/blender are superseded), every NEW run's page rendered no
# preview at all — while the Jobs list showed a thumbnail for the same job,
# because Job#preview_file does handle bp. "The page loads but there's no
# preview" was exactly that asymmetry.
#
# The runner LABEL is the deployment's, so the job's kind comes from the env here
# (with_runners) rather than from a name this test invents: a job is `bp?`
# because its label's KIND is bp, and a test that hardcoded a label would pass on
# one box and fail on the next.
class JobPageBpOutputTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  # The suite's own runner-env harness (same shape as job_steps_test): URLs and
  # KINDS are separate maps, and the cache reset is what makes them take effect.
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
    with_runners(urls: { "CHOPSHOP_RUNNER_BPTEST_URL" => "http://bp.invalid:8796" },
                 kinds: { "CHOPSHOP_RUNNER_BPTEST_KIND" => "bp" }, &block)
  end

  def login!
    post login_path, params: { password: "test-password" },
                     headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  end

  # A real file in storage/uploads, so upload_preview can serve it. Removed by
  # snapshot diff in cleanup_test_uploads — never by a bare prefix glob, which is
  # how a suite run once deleted a live job's artifacts.
  def write_artifact(name, bytes = "<svg xmlns='http://www.w3.org/2000/svg'/>")
    File.binwrite(uploads_dir.join(name), bytes)
    name
  end

  def bp_job(op:, rendered:, name: "bp-#{op}-test", doc: nil)
    doc ||= { "type" => "geometry", "elements" => [{ "kind" => "box" }] }
    Job.create!(name: name, state: "done", source_kind: "raster",
                input_path: Rails.root.join("storage/uploads/#{rendered['file']}").to_s,
                stem: name, runner: "bptest",
                spec: { "bp" => { "op" => op, "doc" => doc, "rendered" => rendered } })
  end

  test "a plot-op bp job's page shows its drawn SVG" do
    with_bp_kind do
      login!
      file = write_artifact("test_bp_plot_#{SecureRandom.hex(4)}.svg")
      job = bp_job(op: "digest", rendered: { "file" => file, "views" => 1,
                                            "content_type" => "image/svg+xml",
                                            "size" => { "width" => 1200, "height" => 640 } })
      assert job.bp?, "the job's kind must be bp for this page to be the bug's page"
      get job_path(job)
      assert_response :success
      assert_includes response.body, 'data-bp-output="digest"',
                      "the bp output card renders, named by its op"
      assert_includes response.body, "Plot output", "a drawn artifact reads as Plot output"
      assert_includes response.body, upload_preview_jobs_path(name: file),
                      "and points at the drawn document"
      assert_includes response.body, "1200×640", "the drawing's own size is stated"
      assert_includes response.body, "The SVG is the deliverable"
      cleanup_test_uploads(/\Atest_bp_/)
    end
  end

  test "a blender-op bp job's page shows every rendered view" do
    with_bp_kind do
      login!
      files = 3.times.map { |i| write_artifact("test_bp_blender_#{i}_#{SecureRandom.hex(3)}.png", "PNG#{i}") }
      job = bp_job(op: "blender",
                   rendered: { "file" => files.first, "files" => files, "views" => 3,
                               "engine" => "workbench", "glb" => "test_bp_scene.glb",
                               "size" => { "width" => 480, "height" => 360 } })
      get job_path(job)
      assert_response :success
      assert_includes response.body, 'data-bp-output="blender"'
      assert_includes response.body, "Blender output", "a rendered artifact reads as Blender output"
      assert_includes response.body, "workbench", "the engine that rendered it"
      assert_includes response.body, "3 files", "every view is accounted for"
      files.each do |f|
        assert_includes response.body, upload_preview_jobs_path(name: f),
                        "#{f} must have a tile — a multi-view render is not one image"
      end
      assert_includes response.body, "Download scene (.glb)",
                      "the scene is offered as a download, not as a tile that cannot show it"
      cleanup_test_uploads(/\Atest_bp_/)
    end
  end

  test "the job page and the Jobs list agree on a bp job's preview file" do
    with_bp_kind do
      login!
      file = write_artifact("test_bp_agree_#{SecureRandom.hex(4)}.png", "PNG")
      job = bp_job(op: "generate", rendered: { "file" => file, "views" => 1 })

      # The list's thumbnail is Job#preview_file; the page's tile is
      # bp_output_file. Two readings of ONE artifact, so they must not diverge —
      # and the divergence was the bug.
      assert_equal file, job.preview_file, "the list's thumbnail is the bp artifact"
      assert_equal file, job.bp_output_file, "and so is the page's tile"
      assert job.preview_from_upload?, "a generated artifact is a local upload, not a runner file"

      get job_path(job)
      assert_includes response.body, upload_preview_jobs_path(name: file)
      cleanup_test_uploads(/\Atest_bp_/)
    end
  end

  test "a bp job with no rendered artifact renders no output card" do
    with_bp_kind do
      login!
      job = bp_job(op: "tree", rendered: {})
      get job_path(job)
      assert_response :success
      refute_includes response.body, "data-bp-output",
                      "no artifact means no output card — not an empty one"
      cleanup_test_uploads(/\Atest_bp_/)
    end
  end

  test "the bp accessors read spec.bp, and the legacy ones still read their own blocks" do
    # The page depends on bp_output_file/bp_frames; the LEGACY plot/blender
    # accessors must keep working for rows created before bp absorbed them (the
    # live box still has plot-kind rows). This pins both, so "add bp" cannot
    # quietly mean "replace plot".
    bp = Job.new(spec: { "bp" => { "op" => "blender",
                                   "rendered" => { "file" => "a.png", "files" => %w[a.png b.png] } } })
    assert_equal "a.png", bp.bp_output_file
    assert_equal %w[a.png b.png], bp.bp_frames
    assert bp.bp_blender?

    legacy_plot = Job.new(spec: { "plot" => { "op" => "log", "rendered" => { "file" => "p.svg" } } })
    assert_equal "p.svg", legacy_plot.plot_output_file

    legacy_blender = Job.new(spec: { "blender" => { "op" => "render",
                                                    "rendered" => { "file" => "b.png" } } })
    assert_equal "b.png", legacy_blender.blender_output_file
  end
end
