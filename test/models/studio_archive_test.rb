require "test_helper"

# The 7z a job's Download produces when the STUDIO holds the deliverable.
#
# The controller's fallback -- that a bp job downloads at all -- is covered by
# test/controllers/job_download_test.rb. What is pinned HERE is the builder's own
# contract, the same set FluxArchiveTest pins for the flux bundle: a job's spec
# is editable text, so a name out of it must never reach the filesystem or a 7z
# argv; a job with nothing to bundle is an ERROR rather than an empty archive;
# and a box with no 7z is a reported state, not a crash.
class StudioArchiveTest < ActiveSupport::TestCase
  SVG = '<svg xmlns="http://www.w3.org/2000/svg"/>'.freeze
  ART = "test_studio_art.svg".freeze

  DOC = { "type" => "geometry", "elements" => [{ "kind" => "box" }] }.freeze

  def with_bp_kind
    saved = {}
    %w[CHOPSHOP_RUNNER_STAB_URL CHOPSHOP_RUNNER_STAB_KIND].each { |k| saved[k] = ENV[k] }
    begin
      ENV["CHOPSHOP_RUNNER_STAB_URL"] = "http://bp.invalid:8796"
      ENV["CHOPSHOP_RUNNER_STAB_KIND"] = "bp"
      Job.reset_runners_cache!
      yield
    ensure
      saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
      Job.reset_runners_cache!
    end
  end

  def uploads
    Rails.root.join("storage", "uploads")
  end

  def staging
    Rails.root.join("storage", "archives")
  end

  def write_upload(name, bytes = SVG)
    uploads.mkpath
    uploads.join(name).binwrite(bytes)
  end

  def job_with(rendered, name: "probe")
    Job.create!(name: name, state: "done", source_kind: "raster", input_path: "",
                stem: name, runner: "stab",
                spec: { "bp" => { "op" => "digest", "doc" => DOC, "rendered" => rendered } })
  end

  def with_path(value)
    original = ENV["PATH"]
    ENV["PATH"] = value
    yield
  ensure
    ENV["PATH"] = original
  end

  def cleanup
    # UploadsSandboxHelper: only the files THIS test added. Deleting every
    # plot_*.svg or blender_*.png emptied the LIVE uploads directory of every
    # real bp job.
    cleanup_test_uploads(/\Atest_studio_/)
  end

  test "a job with nothing to bundle is an error, not an empty archive" do
    with_bp_kind do
      job = job_with({})
      assert_empty job.studio_artifacts, "nothing was drawn, so there is nothing to hold"

      error = assert_raises(StudioArchive::Unavailable) { StudioArchive.new(job).build }
      assert_match(/no artefact/, error.message)
    end
  end

  test "a name out of the spec never reaches the filesystem or a 7z argv" do
    with_bp_kind do
      write_upload(ART)
      # A parent, a separator and a plain traversal: each is refused by NAME_RE,
      # so none of them can name an entry in the bundle or a path on disk.
      [ "../../etc/passwd", "sub/dir.svg", "a;b.svg" ].each do |bad|
        job = job_with({ "file" => bad })
        assert_empty job.studio_artifacts,
                     "#{bad.inspect} is not a safe basename, so the studio does not hold it"
        assert_raises(StudioArchive::Unavailable, "#{bad.inspect} must not be bundled") do
          StudioArchive.new(job).build
        end
      end

      # And the safe name beside them still bundles.
      ok = job_with({ "file" => ART })
      names, = unpack_7z(StudioArchive.new(ok).build)
      assert_includes names, ART
    end
  ensure
    cleanup
  end

  test "a hostile name that EXISTS on disk is still refused by the name rule" do
    # The loop above alone is a test that CANNOT FAIL: none of those names is
    # ever on disk, so widening NAME_RE leaves every assertion true (review
    # finding, #98). This writes the hostile name for real, so the NAME RULE --
    # not the file's absence -- is what refuses it. The mutation proof: widen
    # NAME_RE to /\A[^\/]+\z/ and this test fails on the first assertion.
    with_bp_kind do
      hostile = "test_studio_a;b.svg"
      write_upload(hostile)
      job = job_with({ "file" => hostile })
      assert_empty job.studio_artifacts,
                   "a shell metacharacter makes the name unsafe even when the file is on disk"
      assert_raises(StudioArchive::Unavailable, "an unsafe name must not be bundled") do
        StudioArchive.new(job).build
      end
    end
  ensure
    cleanup
  end

  test "no 7z on PATH is a reported state, not a crash" do
    with_bp_kind do
      write_upload(ART)
      job = job_with({ "file" => ART })

      with_path("") do
        assert_nil FluxArchive.seven_zip, "an empty PATH finds no 7z"
        error = assert_raises(StudioArchive::Unavailable) { StudioArchive.new(job).build }
        assert_match(/not on PATH/, error.message)
      end
    end
  ensure
    cleanup
  end

  test "the staging directory does not survive the build" do
    with_bp_kind do
      write_upload(ART)
      job = job_with({ "file" => ART })

      assert_empty Dir[staging.join("*")], "nothing was left behind to clean up"
      StudioArchive.new(job).build
      assert_empty Dir[staging.join("*")], "the staging dir is removed on the way out"
    end
  ensure
    cleanup
  end

  test "the bundle's manifest carries the ask and the answer, and what it contains" do
    with_bp_kind do
      write_upload(ART)
      job = job_with({ "file" => ART })

      _names, files = unpack_7z(StudioArchive.new(job).build)
      manifest = JSON.parse(files["job.json"])
      assert_equal job.id, manifest.dig("job", "id")
      assert_equal "probe", manifest.dig("job", "stem")
      assert_equal "digest", manifest.dig("spec", "bp", "op"), "the ask"
      assert_equal ART, manifest.dig("spec", "bp", "rendered", "file"), "the answer"
      assert_equal [ ART ], manifest["artifacts"], "what the bundle actually holds"
    end
  ensure
    cleanup
  end
end
