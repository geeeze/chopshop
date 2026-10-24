# Age-based retention for generated artifacts in storage/uploads.
#
# The studio writes every produced artifact (plot SVGs, blender frames, step
# hand-off files, flux rasters) into storage/uploads so upload_preview can
# serve it. Nothing ever removes them, so the directory grows without bound.
#
# This class deletes generated artifacts older than N days, leaving upload_*
# (the operator's source rasters) completely untouched. The job page and the
# proof are the durable record; previews are regenerable from the spec.
#
# WHY N=7: A chained run + hourly smoke writes these continuously, and the
# job page / proof are the durable record (previews are regenerable), so 7
# days gives a full week of artifacts for debugging/review without letting
# the directory grow without bound.
#
# SAFETY: The deleter is scoped to the exact prefixes the app itself generates
# (plot_, blender_, step_, flux_), never a glob over the live directory.
# upload_* files are the operator's originals and are irreplaceable.
class UploadRetention
  # The prefixes the app itself generates. These are the ONLY prefixes eligible
  # for deletion. A file whose prefix is not in this set is left alone.
  GENERATED_PREFIXES = %w[plot_ blender_ step_ flux_].freeze

  # The default retention period in days.
  DEFAULT_DAYS = 7

  attr_reader :directory, :days, :dry_run

  def initialize(directory: Rails.root.join("storage", "uploads").to_s,
                 days: DEFAULT_DAYS, dry_run: true)
    @directory = Pathname.new(directory)
    @days = days
    @dry_run = dry_run
  end

  # Run the retention routine. Returns a report hash.
  def run
    candidates = find_candidates
    deleted = dry_run ? [] : delete_candidates(candidates)
    {
      directory: directory.to_s,
      days: days,
      dry_run: dry_run,
      candidates: candidates.map(&:to_s),
      deleted: deleted.map(&:to_s),
      count: candidates.size
    }
  end

  # Class method for the recurring task. Actually deletes.
  def self.apply!(directory: Rails.root.join("storage", "uploads").to_s, days: DEFAULT_DAYS)
    new(directory: directory, days: days, dry_run: false).run
  end

  # Class method for dry-run. Reports what would be deleted.
  def self.dry_run(directory: Rails.root.join("storage", "uploads").to_s, days: DEFAULT_DAYS)
    new(directory: directory, days: days, dry_run: true).run
  end

  private

  def find_candidates
    return [] unless directory.directory?

    directory.children.select do |path|
      next false unless path.file?
      next false unless generated_prefix?(path)
      next false unless older_than_threshold?(path)
      true
    end
  end

  def generated_prefix?(path)
    basename = File.basename(path.to_s)
    GENERATED_PREFIXES.any? { |prefix| basename.start_with?(prefix) }
  end

  def older_than_threshold?(path)
    File.mtime(path) < Time.now - days.days
  end

  def delete_candidates(candidates)
    candidates.each do |path|
      File.delete(path)
    end
  end
end
