require "test_helper"

# Starting a BLENDER job: paste a geometry document, the runner renders it, the
# frame is kept.
#
# No service and no Blender are contacted. BlenderClient.render is swapped out
# (its own wire behaviour, including the manifest fetch, is covered in
# test/lib/blender_client_test.rb) so what is asserted here is the ORCHESTRATION,
# which cannot be tested anywhere else: what the studio asks the runner for, what
# it stores, what the job ends up filed as, and what happens when the document is
# missing or the renderer is not there.
#
# Rendering is ASYNC like every other run: the POST only queues a RunJob and
# returns immediately, so a test that needs the render to have happened wraps the
# POST in perform_enqueued_jobs, which runs it inline.
class BlenderJobTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  # A real PNG header, so a stored frame is a frame rather than a renamed text
  # file: the bytes after the magic number are arbitrary.
  PNG = ("\x89PNG\r\n\x1a\n".b + "frame-one").freeze
  PNG_TWO = ("\x89PNG\r\n\x1a\n".b + "frame-two").freeze

  DOC = {
    "elements" => [{ "type" => "rect", "x" => 0, "y" => 0, "width" => 200, "height" => 120 }],
    "render" => { "size" => { "width" => 640, "height" => 480 }, "views" => 1,
                  "engine" => "workbench", "background" => "#1a1a24" }
  }.freeze

  # Runner variables that are not the registry but are read at the same moment,
  # so they have to be isolated with it.
  EXTRA_RUNNER_ENV = %w[CHOPSHOP_FLUX_HANDOFF_RUNNER].freeze

  # Hermetic on purpose: EVERY runner variable is cleared first, so a test sees
  # exactly what it asked for. The box running the suite has real runners
  # configured, and inheriting them would make these assert the deployment
  # instead of the code.
  def with_blender_runners(url: "http://render.invalid:8796")
    saved = {}
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| saved[k] = ENV.delete(k) }
    EXTRA_RUNNER_ENV.each { |k| saved[k] = ENV.delete(k) }
    begin
      ENV["CHOPSHOP_RUNNER_BLENDER_URL"] = url
      ENV["CHOPSHOP_RUNNER_BLENDER_KIND"] = "blender"
      ENV["CHOPSHOP_RUNNER_SVG_URL"] = "http://pipeline.invalid:8791"
      Job.reset_runners_cache!
      yield
    ensure
      ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| ENV.delete(k) }
      EXTRA_RUNNER_ENV.each { |k| ENV.delete(k) }
      saved.each { |k, v| ENV[k] = v }
      Job.reset_runners_cache!
    end
  end

  # Replace the client's render for the duration of a block and put it back in
  # ensure -- the same define_singleton_method swap the plot and flux tests use.
  def stubbing_blender(render:)
    original = BlenderClient.method(:render)
    BlenderClient.define_singleton_method(:render) { |*a, **k| render.call(*a, **k) }
    yield
  ensure
    BlenderClient.define_singleton_method(:render, original)
  end

  def rendered
    { name: "blender-#{SecureRandom.hex(6)}.png", bytes: PNG,
      content_type: "image/png", views: 1, frames: nil, glb: nil, entries: nil, spec: {} }
  end

  def login
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  end

  def start_blender(spec:, name: "scene")
    login
    post jobs_path,
         params: { job: { name: name, runner: "blender", source_kind: "raster",
                          project_id: picker_project.id,
                          spec: JSON.generate(spec) } },
         headers: { "User-Agent" => MODERN_UA }
  end

  # Only the renders THIS test wrote (UploadsSandboxHelper): the glob-only body
  # deleted every blender_*.png in the shared, LIVE storage/uploads.
  def cleanup_renders
    cleanup_test_uploads(/\Ablender_/)
  end

  # --- the request is queued, not rendered on the web thread ---------------

  test "a blender job saves and queues without contacting the renderer" do
    asked = []
    with_blender_runners do
      stubbing_blender(render: ->(base, doc) { asked << [base, doc]; rendered }) do
        start_blender(spec: { "blender" => { "doc" => DOC } })
      end

      # Asserted INSIDE the runner environment: Job#blender? asks the registry
      # what the runner's kind is, and the kind only exists while it is
      # configured.
      assert_response :redirect
      job = Job.last
      assert job.blender?, "the job is filed against a blender runner"
      assert_equal "queued", job.state
      assert_equal DOC, job.blender_doc
      assert_equal 1, job.blender_views
      assert_empty asked, "the POST only queues: the render itself is the worker's"
    end
  end

  # --- the worker renders it ----------------------------------------------

  test "the worker renders the document, stores the PNG and finishes the job" do
    asked = []
    with_blender_runners do
      cleanup_renders
      begin
        stubbing_blender(render: ->(base, doc) { asked << [base, doc]; rendered }) do
          perform_enqueued_jobs do
            start_blender(spec: { "blender" => { "doc" => DOC } })
          end
        end

        assert_response :redirect
        job = Job.last
        assert_equal "done", job.state, "the rendered frame IS the deliverable, so the job is finished"
        assert_equal 0, job.candidate_count, "a blender job traces nothing, so it has no candidates"
        assert job.finished_at.present?
        assert_match(/blender render/, job.prep_summary.to_s)

        # The render went to the blender runner's own base URL, with the document.
        base, doc = asked.first
        assert_equal "http://render.invalid:8796", base
        assert_equal DOC, doc

        # And the frame landed where every other upload lives, named for what it is.
        file = job.blender_output_file
        assert_match(/\Ablender_[0-9a-f]+\.png\z/, file.to_s)
        stored = Rails.root.join("storage", "uploads", file.to_s)
        assert stored.file?, "the rendered frame is on disk"
        assert_equal PNG, File.binread(stored)

        # The render facts, read back off the spec: the ask and the answer in one
        # record, the same block.
        facts = job.spec.dig("blender", "rendered")
        assert_equal 1, facts["views"]
        assert_equal "workbench", facts["engine"]
        assert_equal({ "width" => 640, "height" => 480 }, facts["size"])
        assert_nil facts["glb"], "no export was asked for, so there is none to name"
        assert_equal [file], facts["files"]
        assert_equal "image/png", facts["content_type"]
      ensure
        cleanup_renders
      end
    end
  end

  test "a multi-view render keeps every frame and records the manifest's facts" do
    with_blender_runners do
      cleanup_renders
      begin
        batch = {
          name: "frame-1.png", bytes: PNG, content_type: "image/png",
          views: 2, frames: %w[frame-1.png frame-2.png], glb: "scene.glb",
          entries: [
            { name: "frame-1.png", bytes: PNG, content_type: "image/png" },
            { name: "frame-2.png", bytes: PNG_TWO, content_type: "image/png" }
          ],
          spec: DOC
        }
        stubbing_blender(render: ->(_base, _doc) { batch }) do
          perform_enqueued_jobs do
            start_blender(name: "turntable",
                          spec: { "blender" => { "doc" => DOC.merge("render" => DOC["render"].merge("views" => 2)) } })
          end
        end

        job = Job.last
        assert_equal "done", job.state
        facts = job.spec.dig("blender", "rendered")
        assert_equal 2, facts["views"], "the answer's count, not the document's ask"
        assert_equal %w[frame-1.png frame-2.png], facts["frames"]
        assert_equal "scene.glb", facts["glb"], "the export the manifest named is recorded"
        assert_equal 2, facts["files"].size
        assert_equal 2, job.blender_frames.size

        # Both frames are on disk, in the manifest's order, with their own bytes.
        first = Rails.root.join("storage", "uploads", facts["files"].first)
        second = Rails.root.join("storage", "uploads", facts["files"].last)
        assert_equal PNG, File.binread(first)
        assert_equal PNG_TWO, File.binread(second)
        assert_equal facts["files"].first, job.blender_output_file,
          "the primary frame is the first one the manifest named"
        assert_equal first.basename.to_s, File.basename(job.prep_summary.to_s.split("— ").last)
      ensure
        cleanup_renders
      end
    end
  end

  # --- what the operator is told ------------------------------------------

  test "a blender job without a document is refused, with the reason" do
    asked = []
    with_blender_runners do
      stubbing_blender(render: ->(base, doc) { asked << [base, doc]; rendered }) do
        start_blender(spec: { "blender" => {} })
        assert_response :unprocessable_entity
        assert_match(/BLENDER job needs a document/, response.body)

        start_blender(spec: {})
        assert_response :unprocessable_entity
        assert_match(/BLENDER job needs a document/, response.body)

        start_blender(spec: { "blender" => { "doc" => { "tiling" => {} } } })
        assert_response :unprocessable_entity
        assert_match(/BLENDER document needs an elements list/, response.body)
      end
    end

    assert_empty asked, "nothing was rendered"
    assert_equal 0, Job.unscoped.where(runner: "blender").count,
      "a refused job is not saved and never queued"
  end

  test "a spec whose document arrives as a JSON string is still rendered" do
    asked = []
    with_blender_runners do
      cleanup_renders
      begin
        stubbing_blender(render: ->(base, doc) { asked << [base, doc]; rendered }) do
          perform_enqueued_jobs do
            start_blender(name: "pasted",
                          spec: { "blender" => { "doc" => JSON.generate(DOC) } })
          end
        end

        assert_response :redirect
        assert_equal DOC, asked.first.last,
          "a pasted string document is parsed once, server-side, like the form's is"
      ensure
        cleanup_renders
      end
    end
  end

  test "the renderer's 503 is recorded on the job, not swallowed" do
    with_blender_runners do
      cleanup_renders
      begin
        stubbing_blender(render: ->(*_a) {
          raise BlenderClient::Unavailable,
                "blender 503: Blender is not installed on this host"
        }) do
          perform_enqueued_jobs do
            start_blender(spec: { "blender" => { "doc" => DOC } })
          end
        end

        assert_response :redirect
        job = Job.last
        assert_equal "error", job.state
        assert_match(/\ABLENDER: blender 503/, job.error)
        assert_match(/not installed/, job.error,
          "the service's own reason is the one message that has to reach the operator")
        assert_nil job.blender_output_file, "nothing was stored for a refused render"
      ensure
        cleanup_renders
      end
    end
  end

  test "a blender job whose runner is not configured is refused at create" do
    # The session has no blender runner at all: the runner-inclusion rule
    # refuses the job with a reason on the form, which is the graceful answer --
    # a 422 rather than a queued job that dies in the worker.
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |key| ENV.delete(key) }
    Job.reset_runners_cache!
    start_blender(spec: { "blender" => { "doc" => DOC } })
    assert_response :unprocessable_entity
    assert_match(/Runner is not included in the list/, response.body)
    assert_equal 0, Job.unscoped.where(runner: "blender").count,
      "nothing was saved, so nothing was queued"
  end

  test "a job whose renderer disappears between queueing and running fails gracefully" do
    with_blender_runners do
      job = Job.create!(name: "orphan", state: "queued", source_kind: "raster",
                        runner: "blender", input_path: "", stem: "orphan", owner: "test",
                        spec: { "blender" => { "doc" => DOC } })

      # The deployment loses its renderer between the POST and the worker's turn:
      # the label is no longer a blender runner at all. That is a job the queue
      # cannot dispatch, and it has to be RECORDED rather than raised -- the
      # studio holds the reason, so the operator sees it on the job page.
      ENV.delete("CHOPSHOP_RUNNER_BLENDER_URL")
      ENV.delete("CHOPSHOP_RUNNER_BLENDER_KIND")
      Job.reset_runners_cache!
      refute job.reload.blender?, "the runner is no longer a blender one"

      assert_nothing_raised { RunJob.perform_now(job.id) }
      job.reload
      assert_equal "error", job.state
      assert_match(/Runner is not included in the list|no blender runner is configured/,
                   job.error,
                   "the reason reaches the operator instead of dying in the worker")
      assert_nil job.blender_output_file
      assert job.finished_at.present?, "a failed job is finished, not left running"
    end
  end

  # --- the wire, through the real client ----------------------------------

  test "the stored PNG is the renderer's own bytes, through the real client" do
    seen = []
    with_blender_runners do
      cleanup_renders
      begin
        # Only the HTTP transport is swapped here, so BlenderClient.render and
        # its response parsing all run for real: what is asserted is that the
        # envelope goes to /blender on the blender runner and that the bytes
        # stored are the frame the service answered with.
        original = BlenderClient.method(:post)
        BlenderClient.define_singleton_method(:post) do |url, body, **kwargs|
          seen << [url, body]
          { bytes: PNG, content_type: "image/png", name: BlenderClient.png_name(PNG),
            views: 1, frames: nil, glb: nil, entries: nil }
        end
        begin
          perform_enqueued_jobs do
            start_blender(spec: { "blender" => { "doc" => DOC } })
          end
        ensure
          BlenderClient.define_singleton_method(:post, original)
        end

        job = Job.last
        assert_equal "done", job.state
        assert_equal "http://render.invalid:8796/blender", seen.first.first,
          "the envelope goes to the operation's own route on the blender runner"
        assert_equal({ op: "blender", spec: DOC }, seen.first.last)
        assert_equal PNG, File.binread(Rails.root.join("storage", "uploads", job.blender_output_file)),
          "the bytes stored are the frame the service answered with"
        assert_equal "image/png", job.spec.dig("blender", "rendered", "content_type")
      ensure
        cleanup_renders
      end
    end
  end

  # --- the form ------------------------------------------------------------

  test "the blender kind keeps its panel but is no longer offered on the form" do
    # The 3D render is now the `blender` OPERATION of the combined BP action, so
    # the form offers BP rather than a separate blender target. The KIND stays
    # valid and the panel stays in the markup: an already-filed render job has to
    # keep running, and a deployment still offering the label keeps a working form.
    with_blender_runners do
      login
      get new_job_path, headers: { "User-Agent" => MODERN_UA }
    end
    assert_response :success
    doc = Nokogiri::HTML(response.body)

    options = doc.css("#job_runner option").map { |o| o["value"] }
    refute_includes options, "blender",
      "the superseded label is not offered: BP carries the render as an operation"

    panel = doc.at_css("[data-run-fields='blender']")
    refute_nil panel, "the blender kind must have a panel of its own, or the option is a dead end"
    assert panel["hidden"], "and it starts hidden, like the plot panel"
    refute_nil panel.at_css("#blender_doc"), "the document textarea"
    assert_nil panel.at_css("#plot_op"), "no operation selector: the route IS the operation"

    assert_includes doc.css("[data-run-intro='blender']").text, "Paste",
      "the blurb must say what this panel takes"
  end

  test "the form parses the pasted document in the browser" do
    with_blender_runners do
      login
      get new_job_path, headers: { "User-Agent" => MODERN_UA }
    end
    assert_response :success
    body = response.body

    assert_includes body, "function blenderDocParsed"
    assert_includes body, "function blenderBlock"
    assert_includes body, "function renderBlenderSummary"
    assert_includes body, "A blender job renders a document",
      "an empty paste is refused in the form rather than posted"
  end

  # --- the job page --------------------------------------------------------

  test "the job page shows the rendered PNG through the login-gated preview route" do
    with_blender_runners do
      cleanup_renders
      begin
        file = "blender_a1b2c3.png"
        File.binwrite(Rails.root.join("storage", "uploads", file), PNG)
        job = Job.create!(name: "scene", state: "done", source_kind: "raster",
                          runner: "blender", input_path: "", stem: "scene", owner: "test",
                          spec: { "blender" => { "doc" => DOC,
                                                "rendered" => { "file" => file, "files" => [file],
                                                                "views" => 1, "engine" => "workbench" } } })
        login
        get job_path(job), headers: { "User-Agent" => MODERN_UA }
        assert_response :success

        doc = Nokogiri::HTML(response.body)
        assert_includes doc.text, "Blender output"
        # The rendered frame is a preview in the source stack, beside the plot
        # card's arrangement rather than a new markup path of its own.
        refute_nil doc.at_css(".source-stack a[href='#{upload_preview_jobs_path(name: file)}']"),
          "the frame is served through the existing authenticated preview route, in the source stack"

        # And that route really does serve it, as a PNG.
        get upload_preview_jobs_path(name: file), headers: { "User-Agent" => MODERN_UA }
        assert_response :success
        assert_equal "image/png", response.media_type
      ensure
        cleanup_renders
      end
    end
  end

  test "a blender job with no output yet shows no blender card" do
    with_blender_runners do
      job = Job.create!(name: "pending-scene", state: "queued", source_kind: "raster",
                        runner: "blender", input_path: "", stem: "pending-scene", owner: "test",
                        spec: { "blender" => { "doc" => DOC } })
      login
      get job_path(job), headers: { "User-Agent" => MODERN_UA }
      assert_response :success
      refute_includes response.body, "Blender output",
        "there is nothing to show until the service has rendered it"
    end
  end

  # --- the model's own predicates -----------------------------------------

  test "the model knows the kind, and the preview routes through uploads" do
    with_blender_runners do
      job = Job.create!(name: "preview", state: "done", source_kind: "raster",
                        runner: "blender", input_path: "", stem: "preview", owner: "test",
                        spec: { "blender" => { "doc" => DOC,
                                              "rendered" => { "file" => "blender_deadbe.png",
                                                              "files" => ["blender_deadbe.png"] } } })
      assert job.blender?
      refute job.plot?, "a blender runner is not a plot runner"
      refute job.flux?
      assert_equal "blender_deadbe.png", job.preview_file
      assert job.preview_from_upload?, "a rendered frame lives in storage/uploads"
      assert_equal 1, job.blender_frames.size
    end
  end
end
