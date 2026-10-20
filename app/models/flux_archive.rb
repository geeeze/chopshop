require "fileutils"
require "json"
require "tmpdir"
require "pathname"

# The 7z a FLUX job's Download produces: the provenance the runner's archive
# cannot carry.
#
# A pipeline job's archive is the runner's, and the studio only proxies it. A
# flux job's GENERATION is the studio's own work — the prompt, the model and the
# size, the seed, the reference it was edited from, the colour-inverted twin —
# and none of that exists anywhere on the runner: the runner is handed a raster
# and knows nothing about how it was drawn. So the studio builds its own 7z and
# the runner's archive rides inside it, in trace mode, as pipeline.7z:
#
#   <stem>/
#     flux.json        the prompt, the full generation config, the request, the
#                      render facts — everything needed to reproduce or audit it
#     reference.<ext>  the img2img reference image, when there was one
#     generated/…      every stored raster, under the basename it was stored as
#     inverse.png      the colour-inverted twin
#     pipeline.7z      the runner's own archive (trace mode only)
#
# The runner's archive is INCLUDED rather than unpacked on purpose: it is the
# runner's artefact, produced under the runner contract, and re-writing its
# contents here would be the studio inventing a second pipeline output format.
# One nested archive keeps both halves attributable.
#
# Path safety: a job's spec is user-editable text, so every name that reaches a
# filesystem path — or a 7z argv — is checked against NAME_RE first, and 7z is
# invoked with an ARRAY argv (never a shell string).
class FluxArchive
  NAME_RE = /\A[\w.\-]+\z/.freeze

  # In preference order; whichever is on PATH is used. Absent is a real state
  # (a slim image without p7zip), reported as Unavailable rather than crashing
  # the whole download action.
  SEVEN_ZIP = SevenZip::NAMES

  # Raised when the bundle cannot be built at all — no 7z on the box, or 7z
  # itself failing. The controller turns it into an alert.
  class Unavailable < StandardError; end

  def initialize(job)
    @job = job
  end

  # Build the bundle and return the archive's BYTES. The staging directory is
  # temporary and is removed on the way out, so the caller owns nothing on disk
  # and there is no archive to clean up later.
  def build(pipeline_body: nil, inverse_body: nil)
    raise Unavailable, "a flux provenance archive is only built for a flux job" unless @job.flux?

    binary = self.class.seven_zip
    raise Unavailable, "#{SEVEN_ZIP.join(" / ")} is not on PATH" unless binary

    Dir.mktmpdir("flux-archive-", staging_root.to_s) do |dir|
      staging = Pathname.new(dir)
      folder = staging.join(bundle_name)
      write_bundle(folder, pipeline_body: pipeline_body, inverse_body: inverse_body)
      # Array argv, so there is NO shell and nothing to inject into: every
      # element is either a literal or one of two names already checked against
      # NAME_RE (bundle_name here; the files inside the folder in write_bundle).
      # Brakeman flags the call anyway -- it cannot see through the array to the
      # whitelist -- and that flag is deliberate: guarding the names and saying
      # so is the defence, not a brakeman ignore.
      built = system(*[ binary, "a", "-t7z", "-mx=5", "-y", "-bd", "#{bundle_name}.7z", bundle_name ],
                     chdir: dir, out: File::NULL, err: File::NULL)
      archive = staging.join("#{bundle_name}.7z")
      raise Unavailable, "7z could not build the archive" unless built && archive.file?
      return archive.binread
    end
  end

  # The 7z to use, or nil when none of the three names is on PATH. The lookup
  # itself is SevenZip's, so this class and StudioArchive cannot disagree about
  # which binary is on the box.
  def self.seven_zip
    SevenZip.binary
  end

  private

  # The bundle's folder and archive name. A job's stem is already slugged
  # ("[^a-z0-9]+" -> "-"), but it is still checked: it is a name that reaches
  # both the filesystem and the 7z argv.
  def bundle_name
    stem = @job.stem.to_s
    NAME_RE.match?(stem) ? stem : "flux-job"
  end

  def staging_root
    path = Rails.root.join("storage", "archives")
    path.mkpath
    path
  end

  def write_bundle(folder, pipeline_body:, inverse_body:)
    folder.mkpath
    folder.join("flux.json").binwrite(JSON.pretty_generate(config_json))

    if (reference = @job.flux_reference_file)
      copy_upload(folder.join("reference#{File.extname(reference)}"), reference)
    end

    generated = folder.join("generated")
    generated.mkpath
    rasters.each { |name| copy_upload(generated.join(name), name) }

    # Trace mode: the runner's own twin, handed in. Raster-only: the twin this
    # studio inverted when the raster landed. Either way it is the SAME twin the
    # job page shows, because the job page reads the same name.
    twin = inverse_body.presence || read_upload(@job.flux_inverse_file)
    folder.join("inverse.png").binwrite(twin) if twin

    folder.join("pipeline.7z").binwrite(pipeline_body) if pipeline_body.present?
  end

  # The rendered raster basenames, checked. A job that has produced nothing
  # yet contributes an empty generated/ rather than an error.
  def rasters
    @job.flux_variations.filter_map do |variation|
      name = variation["file"].to_s
      name if NAME_RE.match?(name)
    end
  end

  def copy_upload(dest, name)
    bytes = read_upload(name)
    dest.binwrite(bytes) if bytes
  end

  # A stored upload's bytes, or nil when the name is not a safe basename or the
  # file is not there. A missing reference is not a reason to fail the whole
  # download — the config JSON still records that it existed.
  def read_upload(name)
    return nil unless NAME_RE.match?(name.to_s)
    path = Rails.root.join("storage", "uploads", name.to_s)
    path.file? ? path.binread : nil
  end

  # Everything the bundle's flux.json carries: the ask (prompt + the config the
  # popup reveals + the raw request block) and the answer (the render facts), so
  # the archive is readable on its own with no studio and no database.
  #
  # "config" is the MERGED view — the request with the primary raster's own
  # render facts folded in — i.e. exactly what the job page's popup showed for
  # that image. "request" and "rendered" are the two halves it was merged from,
  # kept separate so nothing is only visible through the merge.
  def config_json
    request = @job.flux_config.reject { |key, _| %w[rendered handoff].include?(key) }
    # The request's reference may have been posted as a full path; the bundle
    # records the basename, which is what actually names the file.
    request = request.merge("image" => @job.flux_reference_file) if request.key?("image")

    {
      "job" => {
        "id" => @job.id,
        "name" => @job.name,
        "stem" => @job.stem,
        "state" => @job.state,
        "runner" => @job.runner,
        "created_at" => @job.created_at&.iso8601,
        "finished_at" => @job.finished_at&.iso8601
      },
      "flux" => {
        "prompt" => @job.flux_prompt,
        "mode" => @job.flux_mode,
        "config" => @job.flux_reveal_config(@job.flux_variations.first),
        "request" => request,
        "rendered" => @job.flux_config["rendered"],
        "reference" => @job.flux_reference_file,
        "inverse" => @job.flux_inverse_file
      }.compact
    }
  end
end
