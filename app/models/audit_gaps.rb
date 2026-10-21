# THE DATA-DEBT COUNT (issue #95, facelift 3/4) -- what this studio's OWN tables
# say is missing, in counts AND in the literal id lists behind them.
#
# The operator could not answer "how complete is our data" without browsing:
# jobs that left nothing behind, candidates that were never proved, projects
# that never ran, validations that errored. The debt existed and was uncounted,
# so it read as vague patchiness instead of a number that shrinks. This class is
# the number.
#
# SHAPE (the vatican-kb `/api/audit` shape, adapted to the studio's classes):
#
#   { total, needs_attention, groups: [{ key, n, gaps: {field => count},
#                                       unresolved_ids: [...] }],
#     by_project: [{ id, name, jobs, ..., unresolved, unresolved_ids }] }
#
# `total` is every row the audit looked at; `needs_attention` is every row it
# found unresolved. Each `gaps` entry is a CHECK, and its count is the size of
# the exact relation the id list is read off (one two-column pluck feeds both,
# `gap_rows`) -- so a count can never disagree with the list behind it. That is
# the whole point: the app knows what is missing in itself and says so. (Cost
# note: the count is `ids.size` off that pluck, not a SQL COUNT -- the number is
# deliberately the list.)
#
# WHAT IS DELIBERATELY NOT HERE:
#
#   * no derived layer. Every check is a relation over the studio's own tables
#     (Job / Candidate / Validation / Project / Composite). The kb's `no_subtext`
#     join overcounted because it read a derived key set; nothing here does.
#   * no write. The audit counts debt, it does not fix it.
#
# The epistemic-flag gaps of #107 are out of scope and slot in as one more entry
# in GAPS each -- the constant is shaped for them (a `rows` lambda over the flag
# table, a `key`, a `name`), and nothing else in this file changes.
#
# Owner scoping is INHERITED, not re-implemented: Job, Validation, Project and
# Composite carry `Owned`'s default_scope, so their relations are already this
# operator's. Candidate has no owner column of its own -- it belongs to a job --
# so its base relation is `job_id IN (this owner's jobs)`, the same scoping
# EngineMetrics uses. A candidate whose job is GONE belongs to nobody, which is
# exactly why the orphan check is debt.
class AuditGaps
  # Jobs that have SETTLED. `pending`/`queued`/`running` are still in flight,
  # so a blank field on one of those is the run still happening, not debt.
  TERMINAL_STATES = %w[done error cancelled].freeze

  # The classes the audit counts. `states` is the class's own STATES vocabulary
  # (Job, Validation); the others have none and report none rather than
  # inventing one. `path` builds the record URL a filtered id links to -- the
  # candidate has no page of its own, so it links to the job that produced it.
  GROUPS = {
    jobs:      { model: Job,        label: "Jobs",        states: Job::STATES,
                  path: ->(id, _job_id) { "/jobs/#{id}" } },
    candidates: { model: Candidate,  label: "Candidates",  states: nil,
                  path: ->(_id, job_id) { job_id ? "/jobs/#{job_id}" : nil } },
    validations: { model: Validation, label: "Validations", states: Validation::STATES,
                  path: ->(id, _job_id) { "/proofs/#{id}" } },
    projects:  { model: Project,    label: "Projects",    states: nil,
                  path: ->(id, _job_id) { "/projects/#{id}" } },
    composites: { model: Composite,  label: "Composites",  states: nil,
                  path: ->(id, _job_id) { "/composite?id=#{id}" } }
  }.freeze

  # The BASE relation of each group: the rows the audit may look at. A check's
  # `rows` lambda is applied to this, so the owner scoping lives in ONE place.
  BASE = {
    jobs:      -> { Job.all },
    candidates: -> { Candidate.where(job_id: Job.select(:id)) },
    validations: -> { Validation.all },
    projects:  -> { Project.all },
    composites: -> { Composite.all }
  }.freeze

  # The column a group's rows are attributed BY, per class: the row's own
  # `project_id` (Job, Composite), the producing job's (Candidate, Validation
  # -- neither has a `project_id` column of its own), or the row's own `id`
  # (Project, which IS the container).
  PROJECT_KEY = { jobs: :project_id, candidates: :job_id, validations: :job_id,
                  projects: :id, composites: :project_id }.freeze

  # THE CHECKS. One entry per gap; adding a check is ONE LINE. Each `rows`
  # lambda takes the group's base relation and returns the rows unresolved for
  # that check. The count and the id list both come off the returned relation.
  #
  # Four kinds, named the way the issue names them:
  #   missing field  -- an optional-but-expected column is blank on a settled row
  #   orphan         -- the row points at a parent that no longer exists
  #   state         -- a state that can never settle (stranded) or was never run
  #   coverage      -- the domain gaps: no proof, no runs, no sources, no outputs
  GAPS = [
    # ---------------------------------------------------------------- jobs
    { group: :jobs, key: "missing_runner_stem",
      name: "terminal jobs with no runner stem",
      rows: ->(b) { b.where(state: TERMINAL_STATES).where(runner_stem: [nil, ""]) } },
    { group: :jobs, key: "missing_finished_at",
      name: "terminal jobs with no finished_at",
      rows: ->(b) { b.where(state: TERMINAL_STATES).where(finished_at: nil) } },
    { group: :jobs, key: "missing_project",
      name: "jobs with no project",
      rows: ->(b) { b.where(project_id: nil) } },
    { group: :jobs, key: "missing_source",
      name: "jobs with no source",
      rows: ->(b) { b.where(source_id: nil) } },
    { group: :jobs, key: "error_without_message",
      name: "errored jobs with no message",
      rows: ->(b) { b.where(state: "error").where(error: [nil, ""]) } },
    { group: :jobs, key: "orphan_project",
      name: "jobs whose project is gone",
      rows: ->(b) { b.where.not(project_id: nil).where.not(project_id: Project.select(:id)) } },
    { group: :jobs, key: "orphan_source",
      name: "jobs whose source is gone",
      rows: ->(b) { b.where.not(source_id: nil).where.not(source_id: Source.select(:id)) } },
    # `running` with nothing to poll and nothing that can settle it. The SQL
    # spelling is Job.stranded?'s own predicate (see Job.reap_stranded!), so the
    # audit and the reaper cannot disagree about which rows are stranded.
    { group: :jobs, key: "stranded_running",
      name: "jobs stuck running with no runner job",
      rows: ->(b) { b.where(state: "running").where(runner_job_id: [nil, ""])
                       .where("(COALESCE(started_at, created_at)) < ?",
                              Job::STUCK_RUNNING_AFTER.ago) } },

    # ----------------------------------------------------------- candidates
    { group: :candidates, key: "missing_preset",
      name: "candidates with no preset",
      rows: ->(b) { b.where(preset: [nil, ""]) } },
    { group: :candidates, key: "missing_layer_status",
      name: "candidates with no layer gate state",
      rows: ->(b) { b.where(layer_a: [nil, ""]).or(b.where(layer_b: [nil, ""])) } },
    # A candidate that was never PROVED: the operator picked nothing, or the
    # back half was never run. The candidate record page IS the proof page, so
    # this is the studio's own "record with no subtext".
    { group: :candidates, key: "no_proof",
      name: "candidates with no proof",
      rows: ->(b) { b.where.not(id: Validation.where.not(candidate_id: nil).select(:candidate_id)) } },
    # A candidate whose job is gone is deliberately NOT a check here. Candidate
    # has no owner column (ownership rides on the job), so an orphan is
    # unattributable BY CONSTRUCTION: the only relation that finds one ignores
    # both this group's base and Job's owner scope, which (measured in review)
    # puts ANOTHER OPERATOR's orphaned ids in this owner's document and inflates
    # its headline number. There is no scoping that works — a scoped subquery
    # would flag every foreign candidate as an orphan instead. So the class is
    # simply not auditable per-owner; the seeded test pins that a job-less
    # candidate reports NOTHING. (A studio-wide count would have to live outside
    # this endpoint's owner scope, with no ids.)

    # ---------------------------------------------------------- validations
    { group: :validations, key: "errored",
      name: "errored validations",
      rows: ->(b) { b.where(state: "error") } },
    { group: :validations, key: "missing_manifest",
      name: "done validations with no manifest",
      rows: ->(b) { b.where(state: "done").where(manifest: nil) } },
    { group: :validations, key: "missing_candidate",
      name: "validations with no candidate",
      rows: ->(b) { b.where(candidate_id: nil) } },
    { group: :validations, key: "orphan_job",
      name: "validations whose job is gone",
      rows: ->(b) { b.where.not(job_id: Job.select(:id)) } },
    { group: :validations, key: "orphan_candidate",
      name: "validations whose candidate is gone",
      rows: ->(b) { b.where.not(candidate_id: nil).where.not(candidate_id: Candidate.select(:id)) } },
    # The row is created `pending` BEFORE the runner call, so a failure in
    # between strands a phantom back-half run: nothing on the runner side, never
    # executed, and no amount of waiting will finish it.
    { group: :validations, key: "pending_without_runner",
      name: "pending validations with no runner id",
      rows: ->(b) { b.where(state: %w[pending running]).where(runner_validation_id: [nil, ""]) } },

    # ------------------------------------------------------------- projects
    { group: :projects, key: "no_runs",
      name: "projects with no runs",
      rows: ->(b) { b.where.not(id: Job.where.not(project_id: nil).select(:project_id)) } },
    { group: :projects, key: "no_sources",
      name: "projects with no sources",
      rows: ->(b) { b.where.not(id: Source.where.not(project_id: nil).select(:project_id)) } },
    { group: :projects, key: "no_outputs",
      name: "projects with no outputs",
      rows: ->(b) { b.where.not(id: Output.where.not(project_id: nil).select(:project_id)) } },

    # ----------------------------------------------------------- composites
    { group: :composites, key: "missing_project",
      name: "composites with no project",
      rows: ->(b) { b.where(project_id: nil) } },
    { group: :composites, key: "orphan_project",
      name: "composites whose project is gone",
      rows: ->(b) { b.where.not(project_id: nil).where.not(project_id: Project.select(:id)) } },
    # An arrangement with nothing in it. `where(layers: [])` cannot express this:
    # Rails reads an empty array as "no values" and emits `1=0`. The column is
    # JSON (SQLite, the studio's only adapter -- see config/database.yml), so the
    # empty list is the literal `[]` and a NULL is the same debt.
    { group: :composites, key: "empty_layers",
      name: "composites with no layers",
      rows: ->(b) { b.where("layers IS NULL OR layers = '[]'") } }
  ].freeze

  class << self
    # The whole document, as the controller renders it. `total` counts every row
    # the audit looked at; `needs_attention` counts every row it found
    # unresolved -- the number the operator watches shrink.
    def report
      groups = GROUPS.map { |key, meta| build_group(key, meta) }
      {
        owner: Current.user_handle,
        generated_at: Time.current.utc.iso8601,
        total: groups.sum { |g| g[:n] },
        needs_attention: groups.sum { |g| g[:unresolved_ids].size },
        groups: groups,
        by_project: by_project(groups)
      }
    end

    # The id list behind ONE gap, as `[id, record_url]` pairs -- what the
    # filtered HTML view (`/audit?gap=group.key`) renders. Recomputed on request
    # rather than carried in the document: the document stays small enough to
    # diff, and the list is read off the same relation the count came from.
    def rows_for(key)
      group_key, gap_key = key.to_s.split(".", 2)
      meta = GROUPS[group_key&.to_sym]
      check = GAPS.find { |c| c[:group].to_s == group_key && c[:key].to_s == gap_key }
      return [] if meta.nil? || check.nil?

      gap_rows(check).map { |id, key, _gap| [id, meta[:path].call(id, key)] }
    end

    # The unresolved ROWS in ONE project, as `[id, record_url, [gap_key, ...]]`
    # -- what `/audit?project=<id>` renders. One row per RECORD, carrying every
    # gap it fails: a job missing three fields is three counts and ONE row, and
    # listing it three times would make the list longer than the debt. Same
    # walker as the counts, so the list and the number agree. `nil` is the
    # "no project" bucket: the rows whose parent column is blank (or names a
    # project that is gone), which is where the pre-redesign jobs and the
    # project-less composites live.
    def rows_in_project(project_id)
      pid = project_id.to_i if project_id.to_s != "none"
      job_ids = Job.where(project_id: pid).select(:id)
      by_row = {}

      GAPS.each do |check|
        meta = GROUPS[check[:group]]
        gap_rows(check, project_scope(check, pid, job_ids)).each do |id, key, gap_key|
          entry = (by_row[[id, check[:group]]] ||= { url: meta[:path].call(id, key), gaps: [] })
          # QUALIFIED, `group.key`: in a project's list a bare `missing_source`
          # does not say which class it belongs to. The qualified form is also
          # the `?gap=` filter param, so one spelling serves both.
          entry[:gaps] << "#{check[:group]}.#{gap_key}"
        end
      end

      by_row.map { |(id, _group), data| [id, data[:url], data[:gaps].sort] }
            .sort_by { |id, _url, _gaps| id }
    end

    # The base relation of a group -- exposed so the controller can rebuild a
    # single gap without a second copy of the scoping rule.
    def base_for(group)
      BASE[group.to_sym]&.call
    end

    private

    # THE ONE WALKER. Every unresolved row behind a check's RELATION, as
    # `[id, attribution_key, gap_key]`, where `attribution_key` is the column
    # PROJECT_KEY names for that group -- a `project_id` for Job and Composite,
    # the producing `job_id` for Candidate and Validation, the row's own `id`
    # for Project. The group's counts, the per-project breakdown and the two
    # filtered pages all read THIS, so a count and the list behind it cannot
    # disagree. `rel` defaults to the check's own relation; a caller that has
    # already narrowed one (the filtered page) passes it in.
    def gap_rows(check, rel = nil)
      rel ||= check[:rows].call(BASE[check[:group]].call)
      rel.pluck(:id, PROJECT_KEY.fetch(check[:group]))
          .map { |id, key| [id, key, check[:key]] }
    end

    # The base relation of a check narrowed to ONE project. `nil` pid is the
    # "no project" bucket; Candidate and Validation have no `project_id` column,
    # so they are narrowed through the jobs the project owns.
    def project_scope(check, pid, job_ids)
      rel = check[:rows].call(BASE[check[:group]].call)
      column = PROJECT_KEY.fetch(check[:group])
      column == :job_id ? rel.where(job_id: job_ids) : rel.where(column => pid)
    end

    def build_group(key, meta)
      base = BASE[key].call
      checks = GAPS.select { |c| c[:group] == key }
      gaps = {}
      unresolved = {}
      checks.each do |check|
        ids = gap_rows(check).map(&:first)
        gaps[check[:key]] = ids.size
        ids.each { |id| unresolved[id] = true }
      end

      group = {
        key: key.to_s,
        label: meta[:label],
        model: meta[:model].name,
        n: base.count,
        gaps: gaps,
        unresolved_ids: unresolved.keys.sort
      }

      # The class's own state vocabulary, with the members each state has. A
      # state with ZERO members is reported here (and named in
      # `empty_state_names`) rather than inside `gaps`: a state with no members
      # has no ROWS, so it cannot back an id list, and `gaps` stays strictly
      # row-backed -- every count in it is the exact list behind it.
      if meta[:states]
        states = meta[:states].to_h { |s| [s, base.where(state: s).count] }
        group[:states] = states
        group[:empty_state_names] = states.select { |_, n| n.zero? }.keys
      end

      group
    end

    # Debt attributed to the project it belongs to, so the operator can see
    # WHICH workspace the patchiness lives in. The per-class TOTALS are one
    # aggregate query per class; the unresolved rows are read through the same
    # `gap_rows` walker the counts come from, so the two cannot disagree. The
    # candidate/validation rows are attributed through the job that produced
    # them, read from one `jobs` pluck.
    #
    # A row that names a project which does NOT exist is attributed to "no
    # project", not to the phantom id: the debt IS that the parent is gone, and
    # filing it under a project the operator cannot open would hide it.
    def by_project(groups)
      project_names = Project.pluck(:id, :name).to_h
      known_projects = Project.pluck(:id).to_set
      job_project = Job.pluck(:id, :project_id).to_h
      buckets = {}
      unresolved_rows = Hash.new { |h, k| h[k] = Set.new }

      groups.each do |group|
        base = BASE[group[:key].to_sym].call
        project_counts(base, group[:key].to_sym, job_project, known_projects).each do |pid, n|
          key = pid || "none"
          (buckets[key] ||= new_bucket(pid, project_names))[group[:key]] += n
        end

        GAPS.select { |c| c[:group] == group[:key].to_sym }.each do |check|
          gap_rows(check).each do |id, attribution, _gap_key|
            pid = attribute_project(check[:group], attribution, job_project)
            pid = nil if pid && !known_projects.include?(pid)
            key = pid || "none"
            bucket = (buckets[key] ||= new_bucket(pid, project_names))
            # QUALIFIED, `group.key`: `orphan_job` is a real check in three
            # classes, and a bare key would let one class's count overwrite
            # another's in this bucket. The qualified form is also the filter
            # param (`?gap=jobs.orphan_job`), so one spelling serves both.
            bucket["gaps"]["#{check[:group]}.#{check[:key]}"] += 1
            # A row with three gaps is THREE counts and ONE unresolved row --
            # the set is what keeps `unresolved` a count of ROWS. Keyed on the
            # ROW, i.e. [id, group]: ids are only unique within a table, so a
            # job and a candidate can share one and a bare-id set would collapse
            # them into a single row.
            unresolved_rows[key] << [id, group[:key]]
          end
        end
      end

      buckets.each do |key, bucket|
        bucket["unresolved"] = unresolved_rows[key].size
        bucket["unresolved_ids"] = unresolved_rows[key].map(&:first).sort
      end

      buckets.values.sort_by { |b| [b["id"] ? 0 : 1, b["id"].to_i, b["name"]] }
    end

    # An attribution key resolved to a project id: Candidate and Validation are
    # attributed through the job that produced them; the other three carry the
    # project on the row itself.
    def attribute_project(group_key, attribution, job_project)
      PROJECT_KEY.fetch(group_key) == :job_id ? job_project[attribution] : attribution
    end

    # `group(...).count` then SUM by the attributed project. A plain
    # `transform_keys` is WRONG here: two jobs in one project would collapse to
    # one key and the second count would be silently dropped -- which is the
    # common case, not the edge case.
    def project_counts(rel, group_key, job_project, known_projects)
      column = PROJECT_KEY.fetch(group_key)
      rel.group(column).count.each_with_object(Hash.new(0)) do |(key, n), out|
        pid = attribute_project(group_key, key, job_project)
        pid = nil if pid && !known_projects.include?(pid)
        out[pid] += n
      end
    end

    def new_bucket(pid, project_names)
      {
        "id" => pid,
        "name" => pid ? project_names[pid] : "no project",
        "jobs" => 0, "candidates" => 0, "validations" => 0, "composites" => 0,
        "projects" => 0,
        "unresolved" => 0, "unresolved_ids" => [],
        # A counting hash: the first time a gap lands in this bucket it starts
        # at zero rather than raising on `nil + 1`.
        "gaps" => Hash.new(0)
      }
    end
  end
end
