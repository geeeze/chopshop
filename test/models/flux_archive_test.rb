require "test_helper"

# The 7z a flux job's Download produces.
#
# A pipeline job's archive is the runner's; a FLUX job's provenance is the
# studio's own, and this service is where it is packaged. So what is pinned here
# is what a bundle can and cannot be made to contain: a job's spec is editable
# text, a name out of it must never reach the filesystem or a 7z argv, and a
# missing runner archive must never turn a trace-mode bundle into a quietly
# partial one.
class FluxArchiveTest < ActiveSupport::TestCase
  RASTER = "flux_a1b2c3.png".freeze
  REFERENCE = "upload_reference.png".freeze

  EXTRA_RUNNER_ENV = %w[CHOPSHOP_FLUX_HANDOFF_RUNNER].freeze

  def with_flux_runner
    saved = {}
    (ENV.keys.grep(/\ACHOPSHOP_RUNNER_/) + EXTRA_RUNNER_ENV).each { |k| saved[k] = ENV.delete(k) }
    begin
      ENV["CHOPSHOP_RUNNER_FLUX_URL"] = "http://generator.invalid:8795"
      ENV["CHOPSHOP_RUNNER_FLUX_KIND"] = "flux"
      Job.reset_runners_cache!
      yield
    ensure
      (ENV.keys.grep(/\ACHOPSHOP_RUNNER_/) + EXTRA_RUNNER_ENV).each { |k| ENV.delete(k) }
      saved.each { |k, v| ENV[k] = v }
      Job.reset_runners_cache!
    end
  end

  def uploads
    Rails.root.join("storage", "uploads")
  end

  def write_upload(name, bytes = png_bytes)
    uploads.mkpath
    uploads.join(name).binwrite(bytes)
  end

  def png_bytes
    image = ChunkyPNG::Image.new(2, 2, ChunkyPNG::Color.rgb(10, 20, 30))
    image[0, 0] = ChunkyPNG::Color.rgb(0, 0, 0)
    image.to_blob
  end

  # A raster-only flux job whose spec names the rasters it produced. The names
  # are the input this file is really about.
  def flux_job(files:, reference: nil, inverse: nil, runner: "flux")
    spec = { "flux" => { "mode" => "raster", "prompt" => "a probe", "model" => "klein-4b",
                         "width" => 512, "height" => 512, "steps" => "4",
                         "rendered" => { "images" => files.map { |f| { "file" => f, "seed" => 7 } } } } }
    spec["flux"]["image"] = reference if reference
    spec["flux"]["rendered"]["inverse"] = inverse if inverse

    Job.create!(name: "probe", state: "done", source_kind: "raster", runner: runner,
                input_path: "", stem: "probe", spec: spec)
  end

  def staging
    Rails.root.join("storage", "archives")
  end

  test "the bundle carries the config, the reference, every raster and the twin" do
    with_flux_runner do
      write_upload(RASTER)
      write_upload(REFERENCE)
      write_upload("flux_inverse_9f8e.png")
      job = flux_job(files: [ RASTER ], reference: REFERENCE, inverse: "flux_inverse_9f8e.png")

      names, files = unpack_7z(FluxArchive.new(job).build)
      assert_equal [ "flux.json", "generated/#{RASTER}", "inverse.png", "reference.png" ],
                   names, "the whole provenance, and nothing else, in one folder"

      assert_equal png_bytes, files["generated/#{RASTER}"], "the raster travels byte for byte"
      assert_equal png_bytes, files["inverse.png"]
      assert_equal png_bytes, files["reference.png"]

      config = JSON.parse(files["flux.json"])
      assert_equal "a probe", config.dig("flux", "prompt")
      assert_equal "raster", config.dig("flux", "mode")
      assert_equal "flux_inverse_9f8e.png", config.dig("flux", "inverse")
      assert_equal "probe", config.dig("job", "stem")
    end
  ensure
    cleanup
  end

  test "the runner's archive rides inside the bundle, untouched" do
    with_flux_runner do
      write_upload(RASTER)
      job = flux_job(files: [ RASTER ])

      pipeline = "7z\u001c\u0022the runner's own archive\u0022".b
      names, files = unpack_7z(FluxArchive.new(job).build(pipeline_body: pipeline))

      assert_includes names, "pipeline.7z"
      assert_equal pipeline, files["pipeline.7z"],
        "the runner's own bytes, not the studio's idea of them"
    end
  ensure
    cleanup
  end

  # The spec is user-editable text, so every name in it is hostile until proven
  # otherwise: nothing may escape storage/uploads, and nothing may reach the 7z
  # argv unwhitelisted (7z takes array args here, never a shell string).
  test "a name that is not a plain basename is not packed" do
    with_flux_runner do
      write_upload(RASTER)
      job = flux_job(
        files: [ RASTER, "../../../../etc/passwd", "sub/dir.png",
                 "flux_ok.png; touch pwned", "flux_$(id).png", "flux_.png\nrm -rf /" ],
        reference: "../../etc/passwd",
        inverse: "../../../etc/shadow"
      )

      names, files = unpack_7z(FluxArchive.new(job).build)

      assert_includes names, "generated/#{RASTER}"
      assert_equal [ "flux.json", "generated/#{RASTER}" ], names,
        "only the safe raster is packed: no traversal, no metacharacters, no separators"

      names.each do |name|
        assert_match(%r{\A[\w.\-]+(?:/[\w.\-]+)*\z}, name, "#{name.inspect} is a plain bundle path")
        refute_includes name, ".."
      end

      config = JSON.parse(files["flux.json"])
      assert_nil config.dig("flux", "inverse"), "an unsafe twin name is not recorded"
      refute_includes names, "reference.png", "and nothing outside uploads is packed as one"
      # A reference's traversal is reduced to its basename — a name that cannot
      # leave storage/uploads — and since nothing by that name is stored, the
      # bundle records it and packs no image. The reveal on the job page names
      # the same file, so the archive and the popup still agree.
      assert_equal "passwd", config.dig("flux", "reference"),
        "a traversal is neutralised to a basename, never honoured as a path"
    end
  ensure
    cleanup
  end

  test "a reference posted as a full path is recorded as its basename" do
    with_flux_runner do
      write_upload(RASTER)
      write_upload(REFERENCE)
      job = flux_job(files: [ RASTER ], reference: uploads.join(REFERENCE).to_s)

      _names, files = unpack_7z(FluxArchive.new(job).build)
      config = JSON.parse(files["flux.json"])
      assert_equal REFERENCE, config.dig("flux", "reference"),
        "the bundle names the file, not the absolute path it happened to sit at"
      refute_includes files["flux.json"], Rails.root.to_s
    end
  ensure
    cleanup
  end

  test "a bundle whose raster is missing is still built, with what exists" do
    with_flux_runner do
      job = flux_job(files: [ "flux_never_stored.png" ])

      names, files = unpack_7z(FluxArchive.new(job).build)
      assert_equal [ "flux.json" ], names, "a declared raster that is not on disk is not invented"
      assert_equal "flux_never_stored.png",
                   JSON.parse(files["flux.json"]).dig("flux", "rendered", "images", 0, "file")
    end
  ensure
    cleanup
  end

  test "the staging directory does not survive the build" do
    with_flux_runner do
      write_upload(RASTER)
      job = flux_job(files: [ RASTER ])

      assert_empty Dir[staging.join("*")], "nothing was left behind to clean up"
      FluxArchive.new(job).build
      assert_empty Dir[staging.join("*")], "the staging dir is removed on the way out"
    end
  ensure
    cleanup
  end

  test "no 7z on PATH is a reported state, not a crash" do
    with_flux_runner do
      write_upload(RASTER)
      job = flux_job(files: [ RASTER ])

      with_path("") do
        assert_nil FluxArchive.seven_zip, "an empty PATH finds no 7z"
        error = assert_raises(FluxArchive::Unavailable) { FluxArchive.new(job).build }
        assert_match(/not on PATH/, error.message)
      end
    end
  ensure
    cleanup
  end

  test "only a flux job has a flux provenance archive" do
    with_flux_runner do
      job = flux_job(files: [], runner: "mock")
      error = assert_raises(FluxArchive::Unavailable) { FluxArchive.new(job).build }
      assert_match(/only built for a flux job/, error.message)
    end
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
    # flux_*.png emptied the LIVE uploads directory of every real flux job.
    cleanup_test_uploads(/\Aflux_/)
    Dir[uploads.join(REFERENCE)].each { |f| File.delete(f) }
    Dir[staging.join("*")].each { |f| FileUtils.remove_entry(f) }
  end
end
