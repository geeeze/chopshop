require "fileutils"
require "json"
require "tmpdir"
require "pathname"

# The 7z a job's Download produces when the STUDIO holds the deliverable and the
# runner does not.
#
# A pipeline job's archive is the runner's and #download proxies it; a flux
# job's is FluxArchive's, because the studio's provenance is the point. But a bp
# job -- and a legacy plot or blender one -- has NO runner job at all: the
# studio drew or rendered it in-process, wrote the file into storage/uploads and
# recorded its name in the job's own spec. Proxying the runner's archive endpoint
# for such a job was a 404 rendered as a generic failure while the Download
# button still offered it. This is the studio's own bundle instead.
#
# The shape is FluxArchive's, because the two answer the same question with the
# same tools:
#
#   <stem>/
#     job.json     the job's record -- id, name, stem, state, runner, the
#                  operation -- and the FULL spec: the ask (the document) and
#                  the answer (the rendered facts), so the archive is readable
#                  with no studio and no database
#     <file>       the artefact(s) the studio holds, under the basename the job
#                  recorded
#
# Path safety is FluxArchive's rule, unchanged: every name that reaches a
# filesystem path -- or a 7z argv -- is checked against NAME_RE first, and 7z is
# invoked with an ARRAY argv (never a shell string).
class StudioArchive
  NAME_RE = /\A[\w.\-]+\z/.freeze

  # Raised when the bundle cannot be built at all -- no 7z on the box, or the
  # job holds no artefact to put in it. The controller turns it into an alert.
  class Unavailable < StandardError; end

  def initialize(job)
    @job = job
  end

  # Build the bundle and return the archive's BYTES. The staging directory is
  # temporary and is removed on the way out, so the caller owns nothing on disk
  # and there is no archive to clean up later.
  def build
    binary = SevenZip.binary
    raise Unavailable, "#{SevenZip::NAMES.join(" / ")} is not on PATH" unless binary

    files = @job.studio_artifacts
    # An archive of a job that produced nothing would be a manifest claiming a
    # deliverable that is not there -- worse than the alert, because the
    # operator asked for the drawing and got a JSON file.
    raise Unavailable, "this job holds no artefact to archive" if files.empty?

    Dir.mktmpdir("studio-archive-", staging_root.to_s) do |dir|
      staging = Pathname.new(dir)
      folder = staging.join(bundle_name)
      write_bundle(folder, files)
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

  private

  # The bundle's folder and archive name. A job's stem is already slugged
  # ("[^a-z0-9]+" -> "-"), but it is still checked: it is a name that reaches
  # both the filesystem and the 7z argv.
  def bundle_name
    stem = @job.stem.to_s
    NAME_RE.match?(stem) ? stem : "studio-job"
  end

  def staging_root
    path = Rails.root.join("storage", "archives")
    path.mkpath
    path
  end

  def write_bundle(folder, files)
    folder.mkpath
    folder.join("job.json").binwrite(JSON.pretty_generate(manifest(files)))
    files.each { |name| copy_upload(folder.join(name), name) }
  end

  def copy_upload(dest, name)
    bytes = read_upload(name)
    dest.binwrite(bytes) if bytes
  end

  # A stored upload's bytes, or nil when the name is not a safe basename or the
  # file is not there. A name that no longer resolves is SKIPPED rather than
  # failing the bundle: the job's own record is what the archive is for, and a
  # missing file is visible in job.json's `artifacts` list rather than hidden by
  # an error. `Job#studio_artifacts` has already filtered to names that resolve,
  # so this is the belt to that braces.
  def read_upload(name)
    return nil unless NAME_RE.match?(name.to_s)
    path = Rails.root.join("storage", "uploads", name.to_s)
    path.file? ? path.binread : nil
  end

  # Everything job.json carries: the job's identity and its operation, the FULL
  # spec -- the ask and the answer in one record -- and the names of the files
  # the bundle actually contains, because a spec can name a file that is no
  # longer on disk.
  def manifest(files)
    {
      "job" => {
        "id" => @job.id,
        "name" => @job.name,
        "stem" => @job.stem,
        "state" => @job.state,
        "runner" => @job.runner,
        "runner_job_id" => @job.runner_job_id,
        "created_at" => @job.created_at&.iso8601,
        "finished_at" => @job.finished_at&.iso8601
      },
      "spec" => @job.spec,
      "artifacts" => files
    }
  end
end
