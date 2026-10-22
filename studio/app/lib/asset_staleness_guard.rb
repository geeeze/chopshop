# THE STALE-ASSET DEPLOY, MADE VISIBLE AT BOOT (studio #8).
#
# The container's Dockerfile already precompiles assets at image build time
# (`bundle exec rails assets:precompile`), so there is no manual step left to
# automate. What this guard closes instead is the silent drift: a merge that
# touches `app/assets` lands, and if the box is not rebuilt the running process
# keeps serving bytes from before that merge -- no error, no failed job, no
# signal, just a page whose CSS/JS says something `main` no longer says. That
# is the asset half of the hazard AGENTS.md's hot-reload policy already covers
# for the process half: the unit of done is the LIVE PAGE, and the thing that
# makes it live (the build) can silently fall behind the repository.
#
# WHY A WARNING, NOT A BOOT REFUSAL (unlike RecurringQueueGuard). A stale asset
# is a deploy smell, not a runtime fault: the page still renders, every route
# still works, and the digests in the manifest are self-consistent -- the only
# thing wrong is that they are not the digests of the sources in this checkout.
# The recurring-queue guard refuses to boot because the alternative is TOTAL
# SILENCE (a job that sits `ready` forever, invisible from every surface). The
# failure mode here is at worst a visual regression an operator can see and
# report, so the guard says something loud in the log and lets the deploy
# decide what to do about it.
#
# WHY THE MANIFEST MTIME IS THE COMPARISON. Propshaft writes
# `public/assets/.manifest.json` when it precompiles, and a deploy that skips
# `assets:precompile` leaves that manifest at the OLD build's mtime while
# `app/assets` carries the NEW merge's mtime. File mtimes are the only signal
# that does not require parsing the manifest, and the manifest is the only
# timestamp the precompile step leaves behind -- so manifest-older-than-source
# is the one comparison that answers "did this checkout get built after its
# last asset change?" cheaply at every boot.
#
# FALSE-ALARM AVOIDANCE. The check fires ONLY when BOTH a manifest exists AND
# a source is newer than it. A missing manifest is not a stale state -- it is
# either a box that has never precompiled (dev, CI, a checkout before the
# first deploy) or one that serves assets from somewhere else entirely (CDN,
# a reverse proxy, `config.public_file_server.enabled = false`), and warning
# about those on every boot is how a guard gets muted by the second deploy.
# Similarly, a manifest newer than every source is the healthy steady state:
# the last thing that touched the tree was a precompile, which is exactly what
# a correct deploy looks like.
#
# The guard takes a root rather than reading Rails.root directly so the whole
# check can be exercised against a tmpdir with controlled mtimes, the same
# seam RecurringQueueGuard uses.
class AssetStalenessGuard
  # Propshaft's compiled-output manifest. Sprockets -- the other pipeline
  # this could have been -- writes `.sprockets-manifest-*.json` (a glob,
  # because it can be numbered); Propshaft writes exactly this one file, and
  # it is the filename `assets:precompile` emits on this app.
  MANIFEST_NAME = ".manifest.json"

  # A single stale-asset finding, as a readable sentence.
  Finding = Struct.new(:manifest, :newest_source, :source_mtime, :manifest_mtime, keyword_init: true)

  attr_reader :root

  def initialize(root: Rails.root)
    @root = Pathname.new(root)
  end

  # The compiled manifest's path, whether or not it exists. `assets_dir` and
  # `source_dir` are split out from the path joins below so the rake task can
  # point the check at a DIFFERENT root (a build output dir, a staging tree)
  # without the guard knowing anything about it.
  def manifest_path
    assets_dir.join(MANIFEST_NAME)
  end

  def assets_dir
    @root.join("public", "assets")
  end

  def source_dir
    @root.join("app", "assets")
  end

  # The newest source file under app/assets, or nil when the tree has no
  # sources. Sorted by mtime descending so the check reports the single most
  # recent change -- the one an operator recompiling now is responding to --
  # rather than a wall of every file in the tree.
  def newest_source
    sources.max_by { |path| path.mtime }
  end

  def sources
    return [] unless source_dir.exist?

    Dir.glob(source_dir.join("**", "*")).select { |path| File.file?(path) }
       .map { |path| Pathname.new(path) }
  end

  # Every stale-asset finding (zero or one -- the comparison is against a
  # single manifest, so "stale" is a yes/no question with a single piece of
  # evidence to name). Empty when the deploy is sound.
  def findings
    return [] unless stale?

    [ Finding.new(
      manifest: manifest_path.to_s,
      newest_source: newest_source.to_s,
      source_mtime: newest_source.mtime,
      manifest_mtime: manifest_path.mtime
    ) ]
  end

  def stale?
    manifest_path.exist? && newest_source && newest_source.mtime > manifest_path.mtime
  end

  def ok?
    findings.empty?
  end

  # What the boot initializer calls. Returns true when the deploy is sound;
  # otherwise logs a loud WARNING naming the manifest, the newest source that
  # is newer than it, and what to do about it (re-run `assets:precompile`).
  # Never raises: the failure it reports is visible in the served page, so
  # refusing to boot would trade a cosmetic problem for an outage.
  def self.verify!(root: Rails.root, logger: Rails.logger)
    guard = new(root: root)

    if guard.ok?
      true
    else
      finding = guard.findings.first
      logger.warn(
        "ASSET STALENESS: #{finding.manifest} is older than the newest source " \
        "#{finding.newest_source} (#{finding.source_mtime} > #{finding.manifest_mtime}). " \
        "The running process is serving compiled assets from before that source " \
        "changed. Re-run `bundle exec rails assets:precompile` (or rebuild the " \
        "image) and restart."
      )
      false
    end
  end

  # The full human-readable report, used by the rake task and by the tests
  # that assert the warning's CONTENT -- a warning that does not name the
  # manifest, the source, and the fix is decoration.
  def report
    lines = findings.map do |f|
      "  - #{f.manifest} (mtime #{f.manifest_mtime}) is older than " \
      "#{f.newest_source} (mtime #{f.source_mtime})"
    end

    <<~MESSAGE
      ASSET STALENESS: public/assets/#{MANIFEST_NAME} is older than the newest
      source under app/assets. The deploy is serving compiled assets that predate
      the current sources.

      #{lines.join("\n")}

      Fix: re-run `bundle exec rails assets:precompile` and restart the process
      (or rebuild the image, which does this at build time).
    MESSAGE
  end
end
