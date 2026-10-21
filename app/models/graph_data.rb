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
# Nothing here is a join of whole tables for a count: it is a bounded walk of the
# owner's own projects, jobs, candidates and proofs, and it is cheap enough to
# fetch on every graph load.
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

  def self.build
    new.build
  end

  def build
    @nodes = []
    @edges = []

    # Projects first, so a project node exists before any job edge points at it.
    # A project with no jobs is still a node -- "never ran" is the emptiness the
    # marker carries, not an absence.
    projects = Project.all.includes(:jobs).index_by(&:id)
    projects.each_value { |project| add_project(project) }

    Job.all.includes(:candidates, :validations).find_each do |job|
      add_job(job)
      # parent -> child, which is the REVERSE of the kb's child->parent edge. The
      # kb draws a node's own `parent` pointer; this graph reads as the lineage a
      # reader traces -- a project, its jobs, their candidates, the proofs -- so
      # the containment line points the way the eye follows it.
      if projects.key?(job.project_id)
        add_edge(node_id("project", job.project_id), node_id("job", job.id), PARENT)
      end
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

  def add_job(job)
    # A settled job that produced nothing is EMPTY; a job still running is not
    # (it has not had the chance yet), which is why the state is part of the
    # test and not just the candidate count.
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
      add_node(
        id: node_id("candidate", job.id, candidate.id),
        type: "candidate",
        name: candidate.file,
        # A candidate has NO page of its own -- its record IS the job page's
        # candidate row and its Detail control. The file rides along so the page
        # and the candidate-detail JSON endpoint agree on WHICH candidate.
        url: routes.job_path(job, candidate: candidate.file),
        state: candidate_state(candidate),
        art: routes.file_job_path(job, name: candidate.file),
        empty: proved.exclude?(candidate.file)
      )
      add_edge(node_id("job", job.id), node_id("candidate", job.id, candidate.id), PARENT)
    end

    job.validations.each do |proof|
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
      next unless candidate
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
    file = proof.manifest.is_a?(Hash) ? proof.manifest["proof"].presence : nil
    file && routes.file_job_path(job, name: file)
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
