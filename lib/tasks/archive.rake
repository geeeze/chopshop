require "fileutils"
require "json"
require "digest"
require "set"

# ARCHIVE: move owners' studio content OUT of the live database and onto the
# overflow mount, as a bundle that can be restored without the studio running.
#
# Why this exists: the graph is a force-directed walk of every row an operator
# owns, so a studio that has accumulated months of test runs draws more than a
# thousand nodes and takes a visible moment to settle. The debt is not in the
# drawing, it is in the ROW COUNT -- so the fix is to take finished work out of
# the table, not to make the drawing cheaper.
#
# TWO STEPS, DELIBERATELY SEPARATE, so the destructive half can be refused:
#
#   bin/rails "archive:export"   write the bundle; touches NOTHING in the DB
#   bin/rails "archive:purge"    verify the bundle, then delete the rows it holds
#
# The bundle is the authority. `purge` re-reads the manifest, re-hashes every
# file it claims, and refuses to delete a single row if any of them disagrees --
# an archive missing one file is not an archive, and deleting rows against it
# would destroy the only copy.
#
# THE LAYOUT keeps the separation the studio already has: one directory per
# owner handle, one JSON document per class inside it, so a restore is
# per-owner and per-table rather than all-or-nothing.
#
#   <target>/manifest.json                 what was taken, and the hash of every byte
#   <target>/<owner>/<class>.json          the rows, verbatim `attributes`
#   <target>/<owner>/audit.json            the data-debt report as it stood
#   <target>/<owner>/files/uploads/        artefacts this owner's jobs held
#   <target>/<owner>/files/scrapbook/      artefacts this owner favourited
#   <target>/_orphans/scrapbook/           files with no row left to claim them
#
# Candidate rows have no owner column of their own (ownership rides on the job),
# so they are attributed through their job -- the same rule AuditGaps uses.
module ArchiveBundle
  # The classes taken out, with the column their owner is read from. `:via_job`
  # means "read the owner off the producing job" (Candidate). Order matters for
  # the purge: children before parents, so no delete leaves a dangling parent.
  CLASSES = [
    { key: "events",      model: "Event",         owner: :direct },
    { key: "scrapbook",   model: "ScrapbookItem", owner: :direct },
    { key: "validations", model: "Validation",    owner: :direct },
    { key: "candidates",  model: "Candidate",     owner: :via_job },
    { key: "jobs",        model: "Job",           owner: :direct },
    { key: "composites",  model: "Composite",     owner: :direct },
    { key: "sources",     model: "Source",        owner: :direct },
    { key: "outputs",     model: "Output",        owner: :direct },
    { key: "projects",    model: "Project",       owner: :direct }
  ].freeze

  # Rows with a blank owner still belong to somebody -- the pre-owner-scope
  # rows -- so they get their own directory rather than being silently skipped.
  UNOWNED = "_unowned".freeze
  ORPHANS = "_orphans".freeze

  class << self
    def target
      path = ENV["TARGET"].to_s.strip
      raise "set TARGET=<archive dir>, e.g. TARGET=$HOME/overflow/chopshop-studio/archive-20261021" if path.empty?
      File.expand_path(path)
    end

    # Every owner handle the tables carry, plus the blank one.
    def owners
      handles = CLASSES.reject { |c| c[:owner] == :via_job }.flat_map do |cls|
        cls[:model].constantize.unscoped.distinct.pluck(:owner)
      end
      handles.map { |h| h.presence || UNOWNED }.uniq.sort
    end

    # The rows of ONE class belonging to ONE owner bucket, as attribute hashes.
    # Candidate is read through its job, which is the only place its owner lives.
    def rows_for(cls, owner)
      handle = owner == UNOWNED ? nil : owner
      model = cls[:model].constantize.unscoped
      if cls[:owner] == :via_job
        model.where(job_id: Job.unscoped.where(owner: handle).select(:id))
      else
        model.where(owner: handle)
      end
    end

    # ------------------------------------------------------------- export
    def export
      root = target
      FileUtils.mkdir_p(root)
      manifest = { "created_at" => Time.now.utc.iso8601, "target" => root,
                   "owners" => {}, "files" => [], "row_ids" => {} }

      owners.each do |owner|
        dir = File.join(root, owner)
        FileUtils.mkdir_p(File.join(dir, "files", "uploads"))
        FileUtils.mkdir_p(File.join(dir, "files", "scrapbook"))

        counts = {}
        rows = {}
        CLASSES.each do |cls|
          rows[cls[:key]] = rows_for(cls, owner).map(&:attributes)
          counts[cls[:key]] = rows[cls[:key]].size
          File.write(File.join(dir, "#{cls[:key]}.json"),
                     JSON.pretty_generate({ "owner" => owner, "class" => cls[:model],
                                            "count" => counts[cls[:key]], "rows" => rows[cls[:key]] }))
        end

        # The files, read off the RECORD that claims the file -- never off a
        # directory listing -- so the file list can be justified row by row.
        rows["jobs"].each do |row|
          job = Job.unscoped.find_by(id: row["id"]) or next
          job.studio_artifacts.each { |name| copy_file(manifest, root, owner, "uploads", name, dir) }
        end
        rows["scrapbook"].each do |row|
          name = row["file"].to_s
          next unless name.match?(StudioArchive::NAME_RE)
          copy_file(manifest, root, owner, "scrapbook", name, dir)
        end

        # The debt report as it stood: the archive explains itself, so the gaps
        # that were on screen when the rows went out are in the bundle.
        Current.user_handle = owner == UNOWNED ? nil : owner
        File.write(File.join(dir, "audit.json"), JSON.pretty_generate(AuditGaps.report))

        manifest["owners"][owner] = counts
        manifest["row_ids"][owner] = CLASSES.to_h { |c| [c[:key], rows[c[:key]].map { |r| r["id"] }] }
        puts "#{owner}: #{counts.map { |k, v| "#{k}=#{v}" }.join(" ")}"
      end

      # Files nothing claims any more. The rows are only ids to them, so they
      # are carried across rather than deleted: an orphan file may be the only
      # copy of somebody's drawing. Both stores are walked -- a job's artefacts
      # live in uploads, a favourited one in scrapbook -- because a job that was
      # deleted (or came from a spec that named no artefact) leaves its raster
      # behind with nothing pointing at it.
      Current.user_handle = nil
      ["scrapbook", "uploads"].each do |kind|
        claimed = manifest["files"].select { |f| f["kind"] == kind }.map { |f| f["name"] }.to_set
        FileUtils.mkdir_p(File.join(root, ORPHANS, kind))
        orphans = 0
        Dir.children(Rails.root.join("storage", kind)).each do |name|
          next if claimed.include?(name)
          src = Rails.root.join("storage", kind, name)
          next unless File.file?(src)
          FileUtils.cp(src, File.join(root, ORPHANS, kind, name))
          orphans += 1
        end
        manifest["orphan_files"] ||= {}
        manifest["orphan_files"][kind] = orphans
      end

      File.write(File.join(root, "manifest.json"), JSON.pretty_generate(manifest))
      puts "wrote #{root}: #{manifest["files"].size} claimed files, " \
           "#{manifest["orphan_files"]} orphans, " \
           "#{manifest["owners"].values.sum { |h| h.values.sum }} rows"
      manifest
    end

    def copy_file(manifest, root, owner, kind, name, dir)
      return unless name.to_s.match?(StudioArchive::NAME_RE)
      src = Rails.root.join("storage", kind, name)
      return unless src.file?
      dest = File.join(dir, "files", kind, name)
      FileUtils.cp(src, dest)
      manifest["files"] << { "owner" => owner, "kind" => kind, "name" => name,
                             "bytes" => File.size(dest),
                             "sha256" => Digest::SHA256.file(dest).hexdigest }
    end

    # -------------------------------------------------------------- purge
    def purge
      root = target
      manifest = JSON.parse(File.read(File.join(root, "manifest.json")))

      # VERIFY FIRST, DELETE SECOND. Every file the manifest names must be
      # present with the bytes it recorded; a short file means the bundle is not
      # the archive it claims to be, and the purge stops before touching a row.
      broken = manifest["files"].reject do |f|
        path = File.join(root, f["owner"], "files", f["kind"], f["name"])
        File.file?(path) && Digest::SHA256.file(path).hexdigest == f["sha256"]
      end
      unless broken.empty?
        raise "REFUSING TO PURGE: #{broken.size} archived file(s) missing or changed; " \
              "first: #{broken.first["owner"]}/#{broken.first["name"]}"
      end
      puts "verified #{manifest["files"].size} files against the manifest"

      deleted = Hash.new(0)
      ActiveRecord::Base.transaction do
        manifest["row_ids"].each_value do |per_class|
          CLASSES.each do |cls|
            ids = per_class[cls[:key]] || []
            next if ids.empty?
            # `unscoped`: the ids came off the archive, not off a scoped
            # relation, and the unowned bucket has no handle to scope by.
            deleted[cls[:key]] += cls[:model].constantize.unscoped.where(id: ids).delete_all
          end
        end
      end

      # Files go last: the rows are gone only once the bundle is verified, and a
      # source file is removed only once its archived copy matches byte for byte.
      removed = 0
      manifest["files"].each do |f|
        path = Rails.root.join("storage", f["kind"], f["name"])
        next unless path.file? && Digest::SHA256.file(path).hexdigest == f["sha256"]
        File.delete(path)
        removed += 1
      end
      # Orphans too: only once the archived copy matches byte for byte, so a
      # file that changed between export and purge stays where it is.
      ["scrapbook", "uploads"].each do |kind|
        Dir.children(Rails.root.join("storage", kind)).each do |name|
          path = Rails.root.join("storage", kind, name)
          dest = File.join(root, ORPHANS, kind, name)
          next unless File.file?(path) && File.file?(dest)
          next unless Digest::SHA256.file(path).hexdigest == Digest::SHA256.file(dest).hexdigest
          File.delete(path)
        end
      end

      puts "deleted rows: #{deleted.map { |k, v| "#{k}=#{v}" }.join(" ")}"
      puts "deleted files: #{removed} claimed"
      deleted
    end

    # ------------------------------------------------------ reattribute
    # `studio_artifacts` only knows the jobs the STUDIO rendered (bp, plot,
    # blender). A flux or upload-backed job names its raster inside its own spec
    # instead, so the first export put every one of those files in _orphans --
    # preserved, but not under the owner that owns it. This walks the orphan
    # uploads back to the job whose spec names them and files them under that
    # owner, moving bytes on the same store rather than copying them again.
    #
    # A file named by no spec stays an orphan: a guess would put somebody's
    # drawing under another operator's name, which is worse than an honest
    # "_orphans".
    def reattribute_uploads
      root = target
      manifest = JSON.parse(File.read(File.join(root, "manifest.json")))
      specs = Job.unscoped.pluck(:id, :owner, :spec)
                 .map { |id, owner, spec| [id, owner.presence || UNOWNED, spec.to_s] }

      moved = 0
      Dir.children(File.join(root, ORPHANS, "uploads")).each do |name|
        next unless File.file?(File.join(root, ORPHANS, "uploads", name))
        hit = specs.find { |(_id, _owner, spec)| spec.include?(name) }
        next if hit.nil?
        owner = hit[1]
        dest_dir = File.join(root, owner, "files", "uploads")
        FileUtils.mkdir_p(dest_dir)
        src = File.join(root, ORPHANS, "uploads", name)
        dest = File.join(dest_dir, name)
        FileUtils.mv(src, dest)
        manifest["files"].reject! { |f| f["kind"] == "uploads" && f["name"] == name }
        manifest["files"] << { "owner" => owner, "kind" => "uploads", "name" => name,
                               "bytes" => File.size(dest),
                               "sha256" => Digest::SHA256.file(dest).hexdigest }
        moved += 1
      end
      manifest["orphan_files"]["uploads"] = Dir.children(File.join(root, ORPHANS, "uploads")).size
      File.write(File.join(root, "manifest.json"), JSON.pretty_generate(manifest))
      puts "reattributed #{moved} uploads; #{manifest["orphan_files"]["uploads"]} still unnamed"
      moved
    end

    # ------------------------------------------------------------ verify
    def verify
      root = target
      manifest = JSON.parse(File.read(File.join(root, "manifest.json")))
      Current.user_handle = nil
      CLASSES.each do |cls|
        live = cls[:model].constantize.unscoped.count
        archived = manifest["owners"].values.sum { |h| h[cls[:key]].to_i }
        printf("%-12s archived=%-5d live-now=%-4d\n", cls[:key], archived, live)
      end
      report = AuditGaps.report
      puts "audit: #{report[:total]} rows / #{report[:needs_attention]} unresolved"
      g = GraphData.build
      puts "graph: #{g[:nodes].size} nodes / #{g[:edges].size} edges"
    end
  end
end

namespace :archive do
  desc "Export every owner's studio content into TARGET as a restorable bundle (read-only)"
  task export: :environment do
    ArchiveBundle.export
  end

  desc "Verify TARGET's bundle against the live rows, then delete exactly those rows"
  task purge: :environment do
    ArchiveBundle.purge
  end

  desc "File orphan uploads under the owner whose job spec names them"
  task reattribute: :environment do
    ArchiveBundle.reattribute_uploads
  end

  desc "Compare TARGET's manifest with what the live tables still hold"
  task verify: :environment do
    ArchiveBundle.verify
  end
end
