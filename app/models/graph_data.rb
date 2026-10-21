# GET /graph.json -- the studio's own records as ONE graph (#96, facelift 4/4).
#
# The operator sees individual jobs, candidates and proofs; nothing renders the
# SHAPE of the system -- which projects are active, which candidates came from
# which runs, which proofs hang off which picks, where the errored runs cluster.
# The relationship data is already in the four tables; this is the read-model
# that serves it. NO new tables, no new columns: every field is read off the
# records that already exist.
#
# One route, two shapes, the way the studio already serves its JSON
# (`GET /jobs/:id` and `/jobs/:id.json`, `GET /audit` and `/audit.json`): `/graph`
# is the page, `/graph.json` is the document. No `/api` namespace -- the kb's
# `/api/graph` is the SHAPE this follows, not a path mandate.
#
# Read-only and owner-scoped by construction: Project and Job carry Owned's
# default_scope, and Candidate / Validation are read through the owner's own
# jobs, so another operator's rows cannot appear in this document at all.
#
# THE SHAPE, and why each field is there:
#
#   nodes: [{ id, type, tier, name, url, state, art, empty }]
#     id     unique across the graph ("job:37"), stable for a given record
#     type   one of TYPES -- the ENTITY CLASS, which is what the colour means
#     tier   A/B/C/D, one per entity class (the kb's tiers, same idea)
#     name   the record's own name, VERBATIM -- it is data, and the view renders
#            it with textContent, never innerHTML (the repo's runner-SVG rule)
#     url    the REAL record this node opens: a project, a job, a proof page, or
#            the job page carrying the candidate's file
#     state  the record's WORK STATE, a separate field from `type` -- the
#            devgraph rule that a class and a state are never the same colour.
#            nil for a project, which is a container and has no run of its own.
#     art    the artwork URL for a node that carries artwork (a candidate's SVG,
#            a proof's render PNG), nil for project and job nodes. The view sets
#            it on an <image> with setAttribute; it is never parsed as markup.
#     empty  the MISSING/EMPTY marker, distinguished from a settled node: a
#            project that never ran, a job that settled with nothing traced, a
#            candidate never proved, a proof with no manifest.
#
#   edges: [{ from, to, kind }]
#     kind   "parent" (a project holds a job, a job holds a candidate -- dashed)
#            or "proof" (the line a pick drew from a job/candidate to its proof)
#
# EDGES POINT parent -> child. That is the REVERSE of the kb's own edges (a node's
# `parent` pointer, child -> parent), and it is a deliberate choice: this graph
# reads as the lineage a reader traces -- a project, its jobs, their candidates,
# the proofs -- so the containment line points the way the eye follows it.
# Direction is cosmetic (no arrowheads), but it is consistent: every line runs
# from the container to the thing it contains.
#
# VISIBILITY: A RECORD IS DRAWN ONLY IF IT STILL HOLDS A FILE. The graph is a
# navigation surface for the operator's WORK, and a record whose artwork is gone
# -- a job that erred before it traced anything, a candidate whose run directory
# was cleaned up, a project that never ran -- is data debt, not work. Drawing
# those turns the picture into a thousand nodes of which most are holes, which is
# exactly what made the graph unreadable. The debt is still counted, in one place,
# by /audit; the graph draws what can be opened and looked at.
#
# Nothing here is a join of whole tables for a count: it is a bounded walk of the
# owner's own projects, jobs, candidates and proofs, and it is cheap enough to
# fetch on every graph load. The file test is one directory listing per job.
class GraphData
  # The four entity classes, in the tier order the graph draws them. A TIER IS
  # THE ENTITY CLASS (the kb's tiers are the same idea); the node's WORK STATE is
  # a separate field, so a class and a state can never be confused for each other
  # (the devgraph rule: work state is shown SEPARATELY from entity class).
  TYPES  = %w[project job candidate proof].freeze
  TIERS  = { "project" => "A", "job" => "B", "candidate" => "C", "proof" => "D" }.freeze
  RADIUS = { "project" => 9, "job" => 7, "candidate" => 5, "proof" => 4 }.freeze

  # An edge's kind decides its stroke: `parent` is the containment line (dashed),
  # `proof` the line a pick drew. Two kinds, no more -- the kb has exactly this
  # pair and a third would need a reason.
  PARENT = "parent".freeze
  PROOF  = "proof".freeze

  # WHERE THE FILES ARE. The graph draws only records that still HOLD a file, so
  # the read-model has to be able to see one. Two stores answer for different
  # jobs:
  #
  #   <runner store>/<runner_job_id>/   a pipeline job's candidates and proofs,
  #                                     bind-mounted read-only from the runner
  #                                     (RUNNER_JOBS_DIR)
  #   storage/uploads/<name>            a bp / plot / blender job's artefact, and
  #                                     anything the studio drew itself
  #
  # Read as one directory listing per job, never a stat per node: a graph of a
  # thousand records would otherwise be a thousand syscalls on a network store.
  def self.runner_jobs_dir
    @runner_jobs_dir ||= ENV.fetch("RUNNER_JOBS_DIR", "/srv/runner-jobs")
  end

  # Test seam: a fixture tree, or a different mount, per process.
  def self.runner_jobs_dir=(path)
    @runner_jobs_dir = path
  end

  def self.build
    new.build
  end

  def build
    @nodes = []
    @edges = []
    drawn_projects = Set.new
    # ONE pluck for the project ids: `exists?` per job would be a query per node,
    # which is the cost this read-model exists to avoid.
    known_projects = Project.pluck(:id).to_set

    # The walk is jobs-first, because a JOB is the thing that holds files: a
    # project is only drawn when one of its jobs survived the test, so a project
    # that never ran cannot appear as an empty container any more.
    Job.all.includes(:candidates, :validations).find_each do |job|
      files = stored_files(job)
      # No stored file, no node: this is the visibility rule, in one line.
      next if files.empty?

      add_job(job, files)
      if job.project_id && known_projects.include?(job.project_id)
        drawn_projects << job.project_id
        # parent -> child, which is the REVERSE of the kb's child->parent edge.
        # The kb draws a node's own `parent` pointer; this graph reads as the
        # lineage a reader traces -- a project, its jobs, their candidates, the
        # proofs -- so the containment line points the way the eye follows it.
        add_edge(node_id("project", job.project_id), node_id("job", job.id), PARENT)
      end
    end

    # Projects last, so only the ones a drawn job reached exist. `empty` is now
    # always false for a drawn project -- it holds at least one job with a file --
    # but it is kept as a field so the shape does not change under a consumer.
    Project.where(id: drawn_projects.to_a).includes(:jobs).find_each do |project|
      add_project(project)
    end

    { nodes: @nodes, edges: @edges }
  end

  # ------------------------------------------------------------- the nodes

  def add_project(project)
    add_node(
      id: node_id("project", project.id),
      type: "project",
      name: project.name,
      url: routes.project_path(project),
      state: nil,
      empty: project.jobs.empty?
    )
  end

  def add_job(job, files)
    # A settled job that produced nothing never reaches here (it has no file),
    # so `empty` is the narrow case of a job that still holds a file but whose
    # own candidates were all cleaned up.
    add_node(
      id: node_id("job", job.id),
      type: "job",
      name: job.name,
      url: routes.job_path(job),
      state: job.state,
      empty: job.candidates.empty? && Job::IN_FLIGHT_STATES.exclude?(job.state)
    )

    proved = job.validations.map(&:file)
    by_id = job.candidates.index_by(&:id)

    job.candidates.each do |candidate|
      # A candidate is drawn only when its OWN file is still there.
      next unless files.include?(candidate.file)
      add_node(
        id: node_id("candidate", job.id, candidate.id),
        type: "candidate",
        name: candidate.file,
        # A candidate has NO page of its own -- its record IS the job page's
        # candidate row and its Findings/Detail popup. The file rides along as
        # `?candidate=<file>`, and jobs/show reads that param on load and
        # presses the matching row's Detail button, so the link lands ON the
        # record rather than one click beside it (#96 review fix).
        url: routes.job_path(job, candidate: candidate.file),
        state: candidate_state(candidate),
        art: routes.file_job_path(job, name: candidate.file),
        empty: proved.exclude?(candidate.file)
      )
      add_edge(node_id("job", job.id), node_id("candidate", job.id, candidate.id), PARENT)
    end

    job.validations.each do |proof|
      # Same rule for the proof: its render has to be on disk to be drawn.
      art_name = proof_file(proof)
      next unless art_name && files.include?(art_name)
      add_node(
        id: node_id("proof", proof.id),
        type: "proof",
        # The operator's name for a proof is the one it PROVES (`proof_06`), never
        # a database id -- the same rule the proof page's title follows.
        name: proof_label(proof.file),
        url: routes.validation_path(proof),
        state: proof.state,
        art: proof_art(job, proof),
        empty: proof.manifest.blank?
      )
      add_edge(node_id("job", job.id), node_id("proof", proof.id), PROOF)
      candidate = by_id[proof.candidate_id]
      next unless candidate && files.include?(candidate.file)
      add_edge(node_id("candidate", job.id, candidate.id), node_id("proof", proof.id), PROOF)
    end
  end

  # A candidate's WORK STATE, derived from its own gate readings -- never from
  # the job's state, which is the RUN's verdict and belongs to the job node.
  #
  #   pending  the sweep has not finished reading it (either layer is pending)
  #   fail     a HARD gate fired -- the band vocabulary's fail (red)
  #   pass     both gates cleared and the runner marked it passed
  #   done     read and settled without passing
  #
  # The candidate's artwork is its own; the state is its own. The two are drawn
  # separately in the view, which is the whole reason they are two fields.
  def candidate_state(candidate)
    return "pending" if candidate.layer_a.blank? || candidate.layer_a.to_s == "pending" ||
                        candidate.layer_b.blank? || candidate.layer_b.to_s == "pending"
    return "fail" if candidate.hard.to_i.positive?
    return "pass" if candidate.passed
    "done"
  end

  # A proof's render, from its own manifest -- the file the proof page itself
  # serves. Nil for a proof that never finished (its manifest is empty), and the
  # view then draws the placeholder rather than a broken image.
  def proof_art(job, proof)
    file = proof_file(proof)
    file && routes.file_job_path(job, name: file)
  end

  # The proof's render FILENAME as the job's own directory holds it (no route,
  # no id): what the visibility test compares against the listing.
  def proof_file(proof)
    proof.manifest.is_a?(Hash) ? proof.manifest["proof"].presence : nil
  end

  # EVERY file a job still holds, as a set of basenames. Two stores, because the
  # studio does not draw all of its own work:
  #
  #   storage/uploads/<name>            what the studio itself wrote (bp, plot,
  #                                     blender renders) -- read off the job's own
  #                                     spec through `studio_artifacts`
  #   <RUNNER_JOBS_DIR>/<runner_job_id>  what the runner traced: candidates and
  #                                     proofs, one directory per run
  #
  # ONE listing per job, never one stat per node. A job with neither store -- an
  # errored run, a cleaned-up stem -- returns an empty set, and the graph then
  # leaves it out.
  def stored_files(job)
    names = job.studio_artifacts.to_set
    stem = job.runner_job_id.to_s
    if stem.present?
      dir = File.join(self.class.runner_jobs_dir, stem)
      names.merge(Dir.children(dir)) if File.directory?(dir)
    end
    names
  rescue SystemCallError
    # A run directory the studio cannot read is, for the purpose of this graph,
    # a run with no files: better a missing node than a page that 500s.
    names
  end

  # ---------------------------------------------------------------- helpers

  def add_node(fields)
    @nodes << {
      id: fields[:id],
      type: fields[:type],
      tier: TIERS.fetch(fields[:type]),
      name: fields[:name].to_s,
      url: fields[:url],
      state: fields[:state],
      art: fields[:art],
      empty: fields[:empty] ? true : false
    }
  end

  # One edge per unordered pair: the kb's dedupe, so a job and a candidate can
  # never be joined twice by two different calls. Direction is from -> to.
  def add_edge(from, to, kind)
    return if from.nil? || to.nil? || from == to
    key = [from, to].sort.join("|")
    return if seen_edges.include?(key)
    seen_edges[key] = true
    @edges << { from: from, to: to, kind: kind }
  end

  def seen_edges
    @seen_edges ||= {}
  end

  def node_id(type, *ids)
    ([type] + ids).join(":")
  end

  # The operator's name for a proof, from the candidate it proves:
  # `candidate_06.svg` -> `proof_06`. Read off the helper so the graph and the
  # proof page's title cannot disagree about what a proof is CALLED.
  def proof_label(file)
    helpers.proof_label(file)
  end

  # The view-context proxy the app's own helpers hang off. Memoised because a
  # graph of N proofs would otherwise build a fresh view context per node.
  def helpers
    @helpers ||= ApplicationController.helpers
  end

  def routes
    Rails.application.routes.url_helpers
  end
end
