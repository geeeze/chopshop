# Password-only user management. There is no username: a handle is an internal
# key for scoping, and the password is the identity a user logs in with.
#
# The reset task exists because "clear a test user" is a routine operator job:
# e2e runs leave a workspace full of jobs, composites and scrapbook copies, and
# the ROWS are only half of it -- a scrapbook item COPIES its bytes into
# storage/scrapbook/, so deleting the row without the file leaks disk quietly
# (see ScrapbookItem). Upload artifacts are deliberately NOT handled here: the
# pipeline's shared output dirs and the studio's upload copies are keyed by
# input stem, and the hourly chopshop-orphan-sweep timer reclaims exactly the
# stems whose job no longer exists. One tool per job.
namespace :users do
  # Handles this task refuses by default. See the guard in `reset` below.
  #
  # Deliberately a list of exact handles and not a pattern: "any account with
  # more than one digit" would protect accounts nobody asked about and give the
  # guard a shape that looks arbitrary. `unodos2` is the operator's own; the
  # disposable one is `unodos3`, which is what the usage example names.
  PROTECTED_HANDLES = %w[unodos2].freeze

  desc "Add a user. Usage: bin/rails 'users:add[handle,password]'"
  task :add, %i[handle password] => :environment do |_task, args|
    handle = args[:handle].to_s.strip
    password = args[:password].to_s
    if handle.blank? || password.blank?
      abort "usage: bin/rails 'users:add[handle,password]'"
    end

    if User.exists?(handle: handle)
      puts "user #{handle} already exists (password unchanged)"
    else
      User.create!(handle: handle, password: password)
      puts "created user #{handle}"
    end
  end

  desc "List user handles (never digests). Usage: bin/rails users:list"
  task list: :environment do
    User.order(:handle).pluck(:handle).each { |handle| puts handle }
  end

  desc "Per-owner rows and artifact bytes. Usage: bin/rails users:inventory"
  task inventory: :environment do
    owners = User.order(:handle).pluck(:handle)
    printf("%-12s %6s %7s %7s %7s %7s %7s %14s\n", "handle", "jobs", "cands",
           "valids", "comps", "events", "scraps", "scrapbook bytes")
    owners.each do |handle|
      items = ScrapbookItem.unscoped.where(owner: handle)
      bytes = items.sum { |i| File.exist?(i.stored_path) ? File.size(i.stored_path) : 0 }
      printf("%-12s %6d %7d %7d %7d %7d %7d %14s\n", handle,
             Job.unscoped.where(owner: handle).count,
             Candidate.unscoped.where(owner: handle).count,
             Validation.unscoped.where(owner: handle).count,
             Composite.unscoped.where(owner: handle).count,
             Event.unscoped.where(owner: handle).count,
             items.count,
             ActiveSupport::NumberHelper.number_to_human_size(bytes))
    end
    stray = Job.unscoped.where.not(owner: owners).or(Job.unscoped.where(owner: nil)).count
    puts "\nrows whose owner is not a current user: #{stray}" if stray.positive?
  end

  # The usage example names the DISPOSABLE account, never the operator's own
  # second account. This is not cosmetic: `users:reset` deletes rows AND
  # scrapbook files for every handle it is given, and the example is the line an
  # agent copies. Pointing the documented example at an account whose password
  # the operator set by hand is how that operator loses a credential and a
  # workspace in one paste (issue #16). The abort below is the second layer.
  desc "Reset owner workspaces: rows + their scrapbook files. " \
       "DRY RUN unless APPLY=1. " \
       "Usage: APPLY=1 bin/rails 'users:reset[unodos3]' " \
       "(unodos2 is the OPERATOR's own account and is refused by this task — " \
       "see PROTECTED_HANDLES below)."
  task :reset, %i[handles] => :environment do |_task, args|
    # Rake splits `users:reset[a,b]` on the comma into SEPARATE args, and only
    # the first is bound to a declared name -- the rest land in args.extras.
    # Reading just args[:handles] silently resets one owner and reports success
    # for the rest, which a dry run caught. Accept all of them.
    handles = [args[:handles], *args.extras].compact
                                              .flat_map { |chunk| chunk.to_s.split(",") }
                                              .map(&:strip).reject(&:empty?).uniq
    abort "usage: bin/rails 'users:reset[handle[,handle]]'  (APPLY=1 to delete)" if handles.empty?

    known = User.pluck(:handle)
    unknown = handles - known
    if unknown.any?
      # A typo must not silently reset nothing and read as success.
      abort "refusing: #{unknown.inspect} are not users (have: #{known.sort.inspect})"
    end

    # THE SECOND LAYER, and the one that does not depend on a reader following
    # the example correctly. `unodos2` is the operator's own second account --
    # not a fixture -- and this task deletes rows AND scrapbook files. The
    # password half of that damage was already caused three times in one day by
    # tooling that treated the account as disposable (issue #16); this refuses
    # the workspace half by name, with a message that says WHY rather than just
    # saying no, so whoever hits it learns the rule instead of working around it.
    #
    # Overridable with ALLOW_OPERATOR_RESET=1 for the case where the operator
    # genuinely means it -- a deliberate act, not a paste of a usage line.
    protected = PROTECTED_HANDLES.select { |h| handles.include?(h) }
    if protected.any? && ENV["ALLOW_OPERATOR_RESET"] != "1"
      abort "refusing to reset #{protected.inspect}: that is the OPERATOR's own " \
            "account, not a test fixture. Its password lives in an operator-owned " \
            "env file and resetting it destroys a real credential (issue #16). " \
            "The disposable account is unodos3. If you genuinely mean to reset the " \
            "operator's workspace, re-run with ALLOW_OPERATOR_RESET=1."
    end

    apply = ENV["APPLY"] == "1"
    mode = apply ? "APPLY" : "DRY RUN"

    # Delete in child-first order. `delete_all` on purpose: it is one DELETE with
    # no callbacks and no model attributes loaded, so a database that is behind
    # the code on a column (a model reading a missing attribute would raise)
    # still resets cleanly.
    #
    # Owner scoping differs per table and guessing it is how a reset orphans
    # rows: `candidates` and `validations` are job-scoped (Candidate has NO owner
    # column at all), while jobs/composites/events/scrapbook_items carry `owner`.
    # So the job ids are resolved FIRST and the children are deleted by job_id --
    # `delete_all` on jobs fires no callbacks, so the dependent: :delete_all on
    # Job never runs.
    plan = {}
    handles.each do |handle|
      jobs = Job.unscoped.where(owner: handle)
      job_ids = jobs.pluck(:id)
      plan[handle] = {
        "job_ids" => job_ids,
        "scrapbook_items" => ScrapbookItem.unscoped.where(owner: handle).to_a,
        "candidates" => Candidate.where(job_id: job_ids),
        "validations" => Validation.unscoped.where(owner: handle).or(
          Validation.unscoped.where(job_id: job_ids)),
        "jobs" => jobs,
        "composites" => Composite.unscoped.where(owner: handle),
        "events" => Event.unscoped.where(owner: handle),
      }
    end

    puts "=== users:reset (#{mode}) ==="
    handles.each do |handle|
      rows = plan[handle]
      files = rows["scrapbook_items"].map(&:stored_path)
      bytes = files.select { |f| File.exist?(f) }.sum { |f| File.size(f) }
      printf("  %-10s jobs %d | candidates %d | validations %d | composites %d | " \
             "events %d | scrapbook %d row(s), %d file(s), %s\n",
             handle, rows["jobs"].count, rows["candidates"].count, rows["validations"].count,
             rows["composites"].count, rows["events"].count,
             rows["scrapbook_items"].size,
             files.count { |f| File.exist?(f) },
             ActiveSupport::NumberHelper.number_to_human_size(bytes))
    end

    unless apply
      puts "\nnothing deleted. Re-run with APPLY=1 to apply."
      puts "upload artifacts are reclaimed by the orphan sweep timer, not here."
      next
    end

    handles.each do |handle|
      rows = plan[handle]
      deleted_files = 0
      rows["scrapbook_items"].each do |item|
        path = item.stored_path
        # Refuse anything that does not resolve inside storage/scrapbook: a bad
        # `file` value must not become an arbitrary unlink.
        root = Rails.root.join("storage", "scrapbook").to_s
        next unless File.expand_path(path.to_s).start_with?(File.expand_path(root) + File::SEPARATOR)
        if File.exist?(path)
          File.delete(path)
          deleted_files += 1
        end
      end
      counts = {}
      %w[candidates validations jobs composites events].each do |name|
        counts[name] = rows[name].delete_all
      end
      ScrapbookItem.unscoped.where(owner: handle).delete_all
      printf("  %-10s deleted jobs %d, candidates %d, validations %d, composites %d, " \
             "events %d, scrapbook rows %d, scrapbook files %d\n",
             handle, counts["jobs"], counts["candidates"], counts["validations"],
             counts["composites"], counts["events"],
             rows["scrapbook_items"].size, deleted_files)
    end
    puts "\nuser row(s) kept: #{handles.inspect} can log in to an empty workspace."
    puts "run the orphan sweep to reclaim upload artifacts: chopshop-orphan-sweep.sh"
  end
end
