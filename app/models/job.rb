class Job < ActiveRecord::Base
  include Owned

  has_many :candidates, dependent: :delete_all
  has_many :validations, dependent: :delete_all

  STATES = %w[pending queued running done error cancelled].freeze
  IN_FLIGHT_STATES = %w[pending queued running].freeze

  # Runner name -> base URL. The KEYS are the labels the studio shows; they are
  # deliberately generic ("mock" plus whatever a deployment adds) because they
  # are data, not identifiers of a particular machine. Values default to loopback
  # so a fresh checkout runs with no configuration.
  #
  # Add a runner with CHOPSHOP_RUNNER_<LABEL>_URL rather than editing this file:
  # a literal here would tie the repo to one host's topology, and the live URL
  # changes whenever that host moves. The label is the env var name with the
  # prefix/suffix stripped and lower-cased, so underscores stay underscores:
  # CHOPSHOP_RUNNER_STUDIO_A_URL gives the label "studio_a".
  RUNNER_DEFAULTS = {
    "mock" => "http://127.0.0.1:8790",
  }.freeze

  RUNNER_URL_RE = /\ACHOPSHOP_RUNNER_[A-Z0-9_]+_URL\z/.freeze

  # Memoised because this is read on every job page render. Keyed on the
  # relevant env slice, so it recomputes when a runner is added but still
  # short-circuits on every render. Call .reset_runners_cache! after mutating
  # ENV in a console or a test.
  #
  # This METHOD is the source, not a constant. A constant snapshot taken at class
  # load reads as a source of truth while ignoring every later change, which made
  # reset_runners_cache! a half-truth: it refreshed the kinds and left the URLs
  # frozen. Everything reads through here now.
  def self.runner_urls
    snapshot = runner_env_snapshot
    if !defined?(@runner_urls) || @runner_urls_env != snapshot
      from_env = snapshot.map do |key, url|
        [key.sub(/\ACHOPSHOP_RUNNER_/, "").sub(/_URL\z/, "").downcase, url]
      end
      @runner_urls = RUNNER_DEFAULTS.merge(from_env.to_h).freeze
      @runner_urls_env = snapshot
    end
    @runner_urls
  end

  def self.runner_env_snapshot
    ENV.keys.grep(RUNNER_URL_RE).map { |k| [k, ENV[k]] }.sort
  end

  def self.reset_runners_cache!
    remove_instance_variable(:@runner_urls) if defined?(@runner_urls)
    remove_instance_variable(:@runner_urls_env) if defined?(@runner_urls_env)
    remove_instance_variable(:@runner_kinds) if defined?(@runner_kinds)
    remove_instance_variable(:@runner_kinds_env) if defined?(@runner_kinds_env)
  end

  def self.runners
    runner_urls
  end

  # A runner's KIND says what it DOES, not where it is. Four exist:
  #
  #   svg  — the runner contract (docs/runner-contract.md): prep, trace, gate.
  #   flux — a generator. It speaks the chopshop-flux service's OWN standard API
  #          (POST /generate, /edit), NOT the runner contract, because other
  #          applications call that API too and it should stay clean rather than
  #          growing a second protocol for this app's benefit.
  #   plot — the geometry source and run reporter. It speaks chopshop-plot's
  #          serve API (POST /generate, /digest, /query, GET /health): a
  #          geometry spec in, an SVG out, plus the cross-run query engine over
  #          `.run.json` records.
  #   blender — chopshop-plot's BLENDER operation, on the same serve surface
  #          (POST /blender): a geometry spec in, and either one rendered frame
  #          back as image/png (views == 1) or a JSON frames manifest plus a GLB
  #          export name (views > 1), the files fetched from GET /files/<name>.
  #          It is a second KIND rather than a second service: what it does is
  #          rasterise geometry in 3D, which is a different job target from
  #          drawing a 2D document, and a deployment may run one without the
  #          other.
  #
  # flux, plot and blender are all Run Job TARGETS but none is a PIPELINE
  # runner: they trace nothing, hold no job state and have no candidates, so
  # none may ever be offered as a hand-off target. What separates them is where
  # the work happens — flux draws a raster for the pipeline to trace, plot draws
  # one SVG and blender draws one frame (or a set of frames) that ARE the
  # deliverable — and that difference lives in the view and in RunJob, never in
  # the runner contract.
  #
  # The default is "svg", so a deployment that sets only _URL keeps working
  # exactly as before and nothing must be renamed to stay correct. That also
  # means an existing label (a host-named one, say) is still a pipeline runner
  # without anyone touching it.
  RUNNER_KIND_RE = /\ACHOPSHOP_RUNNER_[A-Z0-9_]+_KIND\z/.freeze
  RUNNER_KINDS = %w[svg flux plot blender bp].freeze

  def self.runner_kind_snapshot
    ENV.keys.grep(RUNNER_KIND_RE).map { |k| [k, ENV[k]] }.sort
  end

  # label -> kind, defaulted for every configured runner. Memoised like
  # runner_urls, and on the same term: the env slice, so adding a runner
  # recomputes and every other render short-circuits.
  def self.runner_kinds
    snapshot = runner_kind_snapshot
    if !defined?(@runner_kinds) || @runner_kinds_env != snapshot
      explicit = snapshot.map do |key, kind|
        [key.sub(/\ACHOPSHOP_RUNNER_/, "").sub(/_KIND\z/, "").downcase, kind.to_s.strip.downcase]
      end.to_h
      @runner_kinds = runner_urls.keys.to_h { |label| [label, explicit.fetch(label, "svg")] }.freeze
      @runner_kinds_env = snapshot
    end
    @runner_kinds
  end

  def self.runner_kind(label)
    runner_kinds.fetch(label.to_s, "svg")
  end

  def self.flux_runner?(label)
    runner_kind(label) == "flux"
  end

  def self.flux_runners
    runner_urls.keys.select { |label| flux_runner?(label) }
  end

  def self.plot_runner?(label)
    runner_kind(label) == "plot"
  end

  def self.plot_runners
    runner_urls.keys.select { |label| plot_runner?(label) }
  end

  def self.blender_runner?(label)
    runner_kind(label) == "blender"
  end

  def self.blender_runners
    runner_urls.keys.select { |label| blender_runner?(label) }
  end

  # The BP runner: ONE Run Job action for the whole blend-plot service, whose op
  # selector covers all six of that service's operations. It exists so the form
  # offers a single BP target instead of a separate plot one and a blender one —
  # they were always the same service, and the BLENDER page said so in as many
  # words ("the same service as PLOT"). The legacy plot and blender kinds are NOT
  # removed: a job already filed against one has to keep resolving its URL and
  # running, so they stay valid and merely stop being OFFERED (see
  # LEGACY_JOB_KINDS / form_runners).
  def self.bp_runner?(label)
    runner_kind(label) == "bp"
  end

  def self.bp_runners
    runner_urls.keys.select { |label| bp_runner?(label) }
  end

  # The runners a JOB can be filed against: one that traces (svg), one that
  # generates a raster to trace (flux), one that draws a document to keep
  # (plot), or one that renders one (blender). All four are Run Job targets now
  # -- the form switches its fields on the runner's kind, and the plot and
  # blender kinds each have a panel of their own (the JSON document they draw or
  # render). Stated positively, like pipeline_runners, so a new kind is opted IN
  # deliberately -- and note that being a job target is a DIFFERENT question
  # from being a pipeline runner: a plot runner is the former and never the
  # latter, and so is a blender one.
  JOB_KINDS = %w[svg flux plot blender bp].freeze

  def self.job_runners
    runner_urls.keys.select { |label| JOB_KINDS.include?(runner_kind(label)) }
  end

  # The kinds that are SUPERSEDED by bp and are no longer offered to a new job.
  # They are kept separate from JOB_KINDS on purpose: JOB_KINDS answers "may a job
  # be filed against this kind at all", which legacy kinds must still answer YES
  # to or every existing plot/blender row becomes undeletable and unrunnable (the
  # "unknown runner" failure). This list answers the narrower question the FORM
  # asks — "what does a NEW job get offered" — and that is now one BP action.
  LEGACY_JOB_KINDS = %w[plot blender].freeze

  def self.form_runners
    # No fallback to job_runners, deliberately: RUNNER_DEFAULTS always supplies
    # `mock` (an svg runner), so this list is never empty and a defensive
    # fallback would be unreachable code. A box that has a plot runner but has
    # not added its `CHOPSHOP_RUNNER_BP_*` line therefore offers its svg runners
    # and NOT the plot one — that is the intent, and the remedy is the env line
    # rather than a form that quietly shows the superseded pair.
    job_runners.reject { |label| LEGACY_JOB_KINDS.include?(runner_kind(label)) }
  end

  # The three operations chopshop-plot's serve surface exposes, and the only
  # values a plot job's spec["plot"]["op"] may carry. Named once here so the
  # model, the form and the worker all read the same list.
  PLOT_OPS = %w[generate digest query].freeze

  # Every operation chopshop-bp's serve surface exposes, and the only values a
  # bp job's spec["bp"]["op"] may carry. The five drawing operations answer with
  # one SVG document; `blender` answers with rendered files. Named once here so
  # the model, the form and the worker read the same list.
  BP_OPS = %w[generate digest query tree log blender].freeze

  # A pipeline runner is one that speaks the RUNNER CONTRACT, and only an "svg"
  # runner does. Written as "which kind IS a pipeline runner" rather than "which
  # kind is not": the negative form rejected flux and would have silently
  # admitted the next non-pipeline kind (plot) as a hand-off target and as the
  # Run Job default. Any new kind must now be added here deliberately.
  def self.pipeline_runners
    runner_urls.keys.select { |label| runner_kind(label) == "svg" }
  end

  # Which pipeline runner a flux job hands its raster to. An explicit choice
  # wins; otherwise the first non-mock pipeline runner -- the same rule #new
  # uses to pick its default, so the dropdown and the hand-off cannot disagree
  # about which runner is "the" pipeline.
  def self.handoff_runner
    explicit = ENV["CHOPSHOP_FLUX_HANDOFF_RUNNER"].presence&.downcase
    return explicit if explicit && pipeline_runners.include?(explicit)
    pipeline_runners.find { |r| r != "mock" } || pipeline_runners.first
  end

  # A TRACE job's source has to be a RASTER. prep_raster.py opens the source with
  # PIL, which reads raster formats only — so an SVG artwork is not a job with a
  # problem, it is a job that cannot run.
  #
  # Where the rule is ENFORCED: `JobsController#create`, i.e. the one door every
  # real job comes through (the Run Job form, the composite and inverse/reuse
  # hand-offs that prefill it, and an agent POSTing the contract over HTTP). It is
  # deliberately not a model validation: the suite's dominant fixture convention
  # is a filler `.svg` input path, so a model invariant would rewrite ~40 test
  # files while adding nothing the create path does not already cover. A row made
  # by hand in a console is out of the pipeline's way either way.
  #
  # These helpers are the shared VOCABULARY for it, used by the controller's check
  # and by the scrapbook drop route so both refuse in the same words.
  #
  # Three live jobs failed with the same underlying error, reached three ways,
  # before any of this existed:
  #
  #   * a step list chaining `bp generate` into a trace step (validated, ran,
  #     died in the runner),
  #   * a composite whose VECTOR flatten produced an SVG, handed to Run Job,
  #   * a direct POST naming an uploads/*.svg as the artwork.
  #
  # All three surfaced as `UnidentifiedImageError: cannot identify image file
  # '.../upload_x.svg'` — a PIL error naming a library the operator never chose.
  # `source_kind` could not have caught it: it is studio-side bookkeeping the
  # runner ignores, and the jobs above carried "raster" while pointing at an SVG.
  # The FILE is the truth, so the file is what is checked.
  RASTER_INPUT_EXTENSIONS = %w[.png .jpg .jpeg].freeze

  # Whether a file is something the trace stage can open. Deliberately about the
  # EXTENSION: the studio cannot inspect bytes for a file on another box, and the
  # pipeline itself dispatches on the suffix.
  def self.raster_source?(path)
    RASTER_INPUT_EXTENSIONS.include?(File.extname(path.to_s).downcase)
  end

  def raster_source?(path)
    self.class.raster_source?(path)
  end

  # The one place the refusal is WORDED, on the class so every route says the
  # same thing — the model's validation and the upload route that just refused a
  # file both call it. It names the WAY OUT, because "cannot read an SVG" is a
  # dead end when the operator's real intent (trace a drawing) is reasonable and
  # has a real remedy.
  def self.trace_source_refusal(path)
    ext = File.extname(path.to_s).downcase
    shown = ext.presence || "not a file type the trace stage reads"
    "a TRACE job's source must be a #{RASTER_INPUT_EXTENSIONS.join(' / ')} — this one is " \
      "#{shown}. The trace stage preps a raster and cannot open an SVG: render the drawing " \
      "to PNG first (a bp blender step does), or flatten the composite as pixels rather " \
      "than as vectors."
  end

  def trace_source_refusal(path)
    self.class.trace_source_refusal(path)
  end

  validates :name, presence: true
  # A lambda, not a snapshot: the runner list is env-driven and can grow at
  # runtime, so the validation has to ask the same question the form does.
  validates :runner, inclusion: { in: ->(_job) { runners.keys } }

  # A flux job's one required input. The service refuses an empty prompt itself,
  # but a round trip to a GPU box to be told that is a poor way to find out.
  validate :flux_job_needs_a_prompt

  def flux_job_needs_a_prompt
    return if sequenced?
    return unless flux?
    errors.add(:base, "a FLUX job needs a prompt") if flux_prompt.blank?
  end

  # A plot job's required input is the request itself: which of the service's
  # three operations to draw, and the document it draws. The service would
  # refuse a malformed envelope, but an op outside the contract's three would
  # surface as a 404 on a route that does not exist, and a query without run
  # records is the refusal PlotClient.query already raises -- both worth moving
  # to where the operator can still fix them.
  validate :plot_job_needs_an_op_and_a_document

  def plot_job_needs_an_op_and_a_document
    return if sequenced?
    return unless plot?
    unless PLOT_OPS.include?(plot_op)
      errors.add(:base, "a PLOT job needs an operation: one of #{PLOT_OPS.join(', ')}")
    end
    errors.add(:base, "a PLOT job needs a document to draw") unless plot_doc
    if plot_op == "query" && plot_runs.empty?
      errors.add(:base, "a PLOT query needs run records")
    end
  end

  # A blender job's required input is the geometry itself: the document it
  # renders. There is no operation to choose -- the route IS the operation
  # (POST /blender) -- so the one thing that can be missing is the spec, and it
  # is missing when the document carries no `elements` list, which the service
  # would refuse as an invalid spec. Both are refused here, where the operator
  # can still fix them, rather than as a 400 after a round trip.
  validate :blender_job_needs_a_document

  def blender_job_needs_a_document
    return if sequenced?
    return unless blender?
    doc = blender_doc
    if doc.nil?
      errors.add(:base, "a BLENDER job needs a document to render")
      return
    end
    return if doc["elements"].is_a?(Array)
    errors.add(:base, "a BLENDER document needs an elements list")
  end

  # A BP job is ONE action covering the whole blend-plot service, so its rules
  # are the union of the two it replaces: an operation out of the six, and the
  # document that operation reads. What is required of the DOCUMENT depends on
  # the op, because the operations do not read the same kind of document — the
  # drawing operations read a geometry or chart spec, `blender` reads a geometry
  # spec that must carry an `elements` list, and `query` additionally needs the
  # run records it draws across. Refusing each here is the same rule the plot and
  # blender validators applied separately, in one place now that they are one
  # action.
  validate :bp_job_needs_an_op_and_a_document

  def bp_job_needs_an_op_and_a_document
    return if sequenced?
    return unless bp?
    unless BP_OPS.include?(bp_op)
      errors.add(:base, "a BP job needs an operation: one of #{BP_OPS.join(', ')}")
    end
    doc = bp_doc
    if doc.nil?
      errors.add(:base, "a BP job needs a document")
      return
    end
    if bp_op == "blender" && !doc["elements"].is_a?(Array)
      errors.add(:base, "a BP blender document needs an elements list")
    end
    if bp_op == "query" && bp_runs.empty?
      errors.add(:base, "a BP query needs run records")
    end
  end

  # --- the step list: one job, several actions in order ---------------------
  #
  # A job's request has always been ONE runner action: the whole spec for a
  # pipeline (svg) runner, or the kind's own block for the generator, the
  # document runner and the renderer (`spec["flux"]`, `spec["plot"]`,
  # `spec["blender"]`). A job may instead carry an ORDERED STEP LIST under the
  # top-level key `spec["steps"]` — the same per-kind requests, one after
  # another, each naming the runner LABEL it runs on:
  #
  #   { "steps" => [
  #       { "runner" => "flux", "flux" => { "prompt" => "a phoenix", "mode" => "raster" } },
  #       { "runner" => "svg",  "svg"  => { "sweep" => { "preset" => "bw" } } },
  #       { "runner" => "bp",   "input" => "previous",
  #         "blender" => { "doc" => { "extrude" => { "depth" => 40 } } } }
  #     ] }
  #
  # The hand-off declaration rides BESIDE the runner label, not inside the
  # kind's block: `"input"` is the step's own word ("job" or "previous"), and
  # the block is handed to the runner untouched.
  #
  # Three rules shape everything below.
  #
  # 1. BACK-COMPAT IS THE DEFAULT. A spec with no "steps" key behaves EXACTLY as
  #    it did before step lists existed, and `steps` answers ONE IMPLICIT step
  #    built from the job's runner and its per-kind block — so a single-action
  #    job is the one-element case of the same shape, every reader handles one
  #    thing, and no existing row needs migrating.
  #
  # 2. THE STUDIO DRIVES THE CHAIN, NOT THE RUNNER. Every runner this studio
  #    talks to — the pipeline runner included — is STATELESS: it serves ONE
  #    operation per request and remembers nothing about what came before. So a
  #    chain is entirely RunJob's business: it posts step 1, waits for it, then
  #    posts step 2 with step 1's produced file, and so on. No runner grows a
  #    chain concept, a session or a contract change for this.
  #
  # 3. A STEP IS VALIDATED BY THE SAME RULES A WHOLE JOB IS. Each step's kind
  #    validator runs against a throwaway job carrying only that step's block —
  #    never a second copy of the rules — and every message names its step
  #    ("step 2: …"). The single-action validators stand aside while a step list
  #    is the request (see the `return if sequenced?` in each), because a step
  #    list filed against a blender label must not ALSO be asked for a top-level
  #    blender document.
  #
  # Where a step's input comes from, and what a step leaves for the next one, is
  # the hand-off table below. A hand-off that cannot be derived is REFUSED here,
  # naming the step, rather than posted as a step with no input.

  # The one key a step list rides under, inside the same spec hash every other
  # per-kind request uses.
  STEPS_KEY = "steps".freeze

  # Where a step's input file may come from. Absent means "derive it": a kind
  # that cannot run without a source takes the step before it when that step
  # produces something it accepts, and the job's own artwork when it does not.
  STEP_INPUTS = %w[job previous].freeze

  # What each kind does with FILES, which is a different question from what it
  # does with documents:
  #
  #   needs    — the step cannot run at all without a source file.
  #   accepts  — the extensions it can take from the step before it. An EMPTY
  #              list means the kind has no file slot in its service contract,
  #              so a step of that kind cannot be handed a file and says so.
  #   produces — the extension of the local file the step leaves behind.
  STEP_FILE_RULES = {
    # `svg` is the TRACE step, and it needs a RASTER: prep_raster.py opens the
    # hand-off with PIL, which cannot read an SVG at all. Accepting ".svg" here
    # let a perfectly natural-looking chain through — "draw a document with bp,
    # then trace it" — and it died inside the runner as
    # `UnidentifiedImageError: cannot identify image file '.../plot_x.svg'`,
    # naming a library the operator never chose. A drawing has to be RENDERED to
    # PNG before the trace stage can see it (a bp `blender` step produces one, or
    # the artwork can be handed over as a separate job, which is how the
    # blender-render-traced demo ran).
    "svg"     => { needs: true,  accepts: %w[.png .jpg .jpeg].freeze,     produces: ".svg" },
    "flux"    => { needs: false, accepts: %w[.png].freeze,                produces: ".png" },
    "plot"    => { needs: false, accepts: [].freeze,                      produces: ".svg" },
    "blender" => { needs: false, accepts: %w[.svg].freeze,                produces: ".png" },
    # `produces` is nil because a BP step's output depends on its OPERATION —
    # the five drawing operations leave an SVG and `blender` leaves a PNG — so
    # the static table cannot answer it. produced_extension resolves it from the
    # step's own op and is what a following step's `needs` check reads.
    "bp"      => { needs: false, accepts: %w[.svg].freeze,                produces: nil }
  }.freeze

  # A step's OPERATION, declared BESIDE its runner label — the same place the
  # hand-off declaration goes, and for the same reason: the kind's block is
  # posted to the service untouched, so a key the service does not know is a 400
  # waiting to happen. An absent op is the runner's own operation (a pipeline
  # step traces, a bp step draws, a flux step generates), which is what every
  # step filed before this existed means.
  #
  #   compose — the studio composes the layer document the step carries and
  #             stores the resulting SVG. Deliberately NOT a runner operation:
  #             /compose is a route on the pipeline runner, but what makes a
  #             compose work is naming every layer's SOURCE and inlining it
  #             (`ComposeSpec`), and a runner on another box cannot see this
  #             app's storage. So the studio builds the wire spec and the step is
  #             executed studio-side — see `RunJob#run_compose_step`. Only a
  #             runner of KIND svg can carry it, because /compose is that
  #             runner's route.
  STEP_OPS = %w[compose].freeze
  COMPOSE_OP = "compose".freeze

  # A compose step's own file rules. It needs nothing handed to it (every layer
  # names its own source, including the file an EARLIER step of the same chain
  # produced) and it leaves an SVG.
  COMPOSE_STEP_RULES = { needs: false, accepts: [].freeze, produces: ".svg" }.freeze

  # Whether this step is the compose operation rather than its runner's default.
  def self.compose_step?(step)
    step.is_a?(Hash) && step["op"].to_s.strip.downcase == COMPOSE_OP
  end

  # The file rules for a STEP, not a kind: a compose step carries its own,
  # because the kind it is filed under (svg — the pipeline runner's) also
  # describes the trace operation, which does need a raster.
  def self.file_rules_for(step)
    return COMPOSE_STEP_RULES if compose_step?(step)

    label = step.is_a?(Hash) ? step["runner"] : nil
    STEP_FILE_RULES.fetch(runner_kind(label), { needs: false, accepts: [], produces: nil })
  end

  # The per-kind validators, by KIND: one set of rules, run once for a
  # single-action job and once per step of a chain.
  STEP_VALIDATORS = {
    "flux"    => :flux_job_needs_a_prompt,
    "plot"    => :plot_job_needs_an_op_and_a_document,
    "blender" => :blender_job_needs_a_document,
    "bp"      => :bp_job_needs_an_op_and_a_document
  }.freeze

  # The step list, NORMALISED: string keys, a resolved runner label, the kind's
  # own block under the kind's own name, and the input declaration when the step
  # makes one. A job whose spec carries no step list answers one implicit step.
  def steps
    list = raw_steps
    return [implicit_step] unless list.is_a?(Array) && list.any?
    list.map { |step| normalize_step(step) }
  end

  # Whether this job's request is a step list. Deliberately about a NON-EMPTY
  # array: a spec that merely carries the key is not a chain.
  def sequenced?
    raw_steps.is_a?(Array) && raw_steps.any?
  end

  # The step at a 1-based position, or nil. The same numbering the validation
  # messages use.
  def step(number)
    number = number.to_i
    number.positive? ? steps[number - 1] : nil
  end

  # The step list exactly as the spec declares it — unvalidated, so a caller
  # that wants to refuse a malformed one can see what was posted.
  def raw_steps
    spec.is_a?(Hash) ? spec[STEPS_KEY] : nil
  end

  # The step a single-action job is, in the step list's own shape: its runner
  # label plus its per-kind block. Reported for reading (a page showing "what
  # this job will do"), never executed — the single-action paths in RunJob are
  # untouched, which is what keeps a no-steps spec behaving exactly as before.
  def implicit_step
    kind = self.class.runner_kind(runner)
    { "runner" => runner.to_s, kind => step_block(kind) }
  end

  # A step's operation, in the word the page and the ledger read: the declared
  # op when the step has one, otherwise the kind's own name. Nil for a step that
  # is not a step.
  def self.step_operation(step)
    return nil unless step.is_a?(Hash)
    op = step["op"].to_s.strip.downcase
    return op if op.present?

    runner_kind(step["runner"])
  end

  # A step's block in the shape its kind's contract takes. A PIPELINE (svg)
  # job's block is its whole spec: the runner contract takes one `spec`
  # document and that document is what the top level has always been. The other
  # kinds keep their request under their own key.
  def step_block(kind, source = spec)
    return (source.is_a?(Hash) ? source.dup : {}) if kind == "svg"
    block = source.is_a?(Hash) ? source[kind] : nil
    block.is_a?(Hash) ? block.deep_stringify_keys : {}
  end

  # --- execution progress ---------------------------------------------------

  # What the worker has recorded about a chain so far: which step is running,
  # which have finished, what each produced, and which runner job served it.
  # Empty for a single-action job and for a chain that has not started. The
  # shape is documented in docs/step-lists.md; these readers are the only place
  # its keys are named.
  def steps_progress
    raw = read_attribute(:steps_state)
    raw.is_a?(Hash) ? raw : {}
  end

  def steps_recorded
    list = steps_progress["steps"]
    list.is_a?(Array) ? list : []
  end

  # 1-based, or nil before the chain starts.
  def current_step_index
    index = steps_progress["current"]
    index.is_a?(Integer) && index.positive? ? index : nil
  end

  def current_step
    index = current_step_index
    index && steps[index - 1]
  end

  # The label of the runner that served the most recent PIPELINE step, or nil
  # when no step of this chain has posted a runner job yet. A chain's
  # candidates, files and archive live THERE, not on whatever label the job was
  # filed against — so this is what execution_runner answers with once a chain
  # has a pipeline step.
  def pipeline_step_runner
    entry = steps_recorded.reverse.find { |e| e.is_a?(Hash) && e["runner_job_id"].present? }
    entry && entry["runner"].presence
  end

  # The steps' own RUNNER LABELS, in order: what the page lists and what the
  # worker posts to.
  def step_runners
    steps.map { |step| step["runner"] }
  end

  # A step list is validated by the SAME rules a single-action job is, per step,
  # with the step named. Only the two things a step adds to a job — a runner by
  # label, and a hand-off — are checked here.
  validate :step_list_is_a_list_of_runnable_steps

  def step_list_is_a_list_of_runnable_steps
    return unless spec.is_a?(Hash) && spec.key?(STEPS_KEY)
    raw = raw_steps
    unless raw.is_a?(Array)
      errors.add(:base, "a step list (#{STEPS_KEY}) must be a JSON array of steps")
      return
    end
    if raw.empty?
      errors.add(:base, "a step list needs at least one step")
      return
    end
    # Validated through `steps`, the NORMALISED list, so a step whose document
    # arrived as a JSON string is checked against the document the worker will
    # actually post rather than against the string it arrived as.
    normalised = steps
    raw.each_with_index do |step, i|
      number = i + 1
      unless step.is_a?(Hash)
        errors.add(:base, "step #{number}: a step must be a JSON object")
        next
      end
      validate_step(normalised[i], number, i.positive? ? normalised[i - 1] : nil, step["op"])
    end
  end

  def validate_step(step, number, previous, declared_op = nil)
    label = step["runner"].to_s.strip.downcase
    if label.blank?
      return errors.add(:base, "step #{number}: a step needs a runner label")
    end
    unless self.class.runners.key?(label)
      return errors.add(:base,
                        "step #{number}: unknown runner #{label.inspect} — the configured labels are " \
                        "#{self.class.runners.keys.join(', ')}")
    end
    kind = self.class.runner_kind(label)
    unless JOB_KINDS.include?(kind)
      return errors.add(:base, "step #{number}: #{label} is a #{kind} runner, which cannot be a step")
    end
    # The op is read from the step AS IT WAS POSTED: normalisation keeps only the
    # operations that exist, so a typo would otherwise be dropped and the step
    # validated as its kind's default — which reports "a SVG step needs an
    # artwork source" for what is really a misspelled `compose`.
    return if validate_step_op(step, number, kind, declared_op)

    handed = step_takes_previous?(step, kind, previous)
    validate_step_input_placement(step, number, kind)
    validate_step_request(step, number, kind, handed: handed)
    validate_step_handoff(step, number, kind, previous, handed: handed)
  end

  # The OPERATION a step declares, beside its runner label. Validating it here
  # rather than inside the kind's block is the same split the hand-off
  # declaration follows: the block is the service's document and stays the
  # service's shape, while this is the studio's own routing.
  #
  # Returns true when the step is already refused, so the caller stops.
  def validate_step_op(step, number, kind, declared_op = nil)
    op = (declared_op.presence || step["op"]).to_s.strip.downcase
    return false if op.blank?

    unless STEP_OPS.include?(op)
      errors.add(:base, "step #{number}: unknown operation #{op.inspect} — a step may declare " \
                        "#{STEP_OPS.map { |o| %("#{o}") }.join(' or ')}, or none at all for the " \
                        "runner's own operation")
      return true
    end

    # /compose is the pipeline runner's route, so a compose step filed against
    # anything else would post a document no service there serves.
    unless kind == "svg"
      errors.add(:base, "step #{number}: the #{op} operation belongs to a pipeline (svg) runner, " \
                        "and #{step['runner']} is a #{kind} runner")
      return true
    end

    validate_compose_document(step, number)
  end

  def validate_compose_document(step, number)
    doc = step["svg"].is_a?(Hash) ? step["svg"] : {}
    errors.add(:base, "step #{number}: a compose step needs a document with a width, a height and " \
                      "a layers list") if doc.blank?

    %w[width height].each do |key|
      value = doc[key]
      next if value.is_a?(Numeric) && value.to_i.positive?
      next if value.to_s.strip.match?(/\A\d+\z/) && value.to_i.positive?

      errors.add(:base, "step #{number}: a compose document needs a positive #{key}")
    end

    layers = doc["layers"]
    unless layers.is_a?(Array) && layers.any?
      errors.add(:base, "step #{number}: a compose document needs a non-empty layers list")
      return
    end

    layers.each_with_index do |layer, i|
      if !layer.is_a?(Hash)
        errors.add(:base, "step #{number}: layer #{i + 1} must be a JSON object")
      elsif layer["src"].to_s.strip.blank?
        errors.add(:base, "step #{number}: layer #{i + 1} has no source to compose")
      end
    end
  end

  # The hand-off declaration belongs BESIDE the runner label. Inside the kind's
  # block it would be posted to the runner as part of the request, which is a
  # shape the runner's own contract refuses — say so here instead of letting the
  # operator find out from a 400.
  def validate_step_input_placement(step, number, kind)
    return if kind == "svg"
    block = step[kind]
    return unless block.is_a?(Hash) && block.key?("input")
    errors.add(:base, "step #{number}: the input declaration goes beside the runner label, " \
                      "not inside the #{kind} block")
  end

  # Whether this step takes the step before it's file. An explicit "previous" is
  # honoured whatever the kind accepts (the refusal for a kind that takes none
  # comes from validate_step_handoff); otherwise only a kind that cannot run
  # without a source takes one, and only what it accepts.
  def step_takes_previous?(step, kind, previous)
    declared = step["input"].to_s.strip.downcase
    rules = self.class.file_rules_for(step.merge("runner" => step["runner"] || kind))
    declared == "previous" ||
      (declared.blank? && rules[:needs] && previous_produces?(previous, rules[:accepts]))
  end

  # The step's OWN kind rules, run against a throwaway job that carries only
  # this step's block — the same validators a single-action job of that kind
  # runs, so the two cannot drift.
  def validate_step_request(step, number, kind, handed: false)
    if kind == "flux" && step.dig("flux", "mode").to_s == "trace"
      errors.add(:base, "step #{number}: a FLUX step in a step list generates a raster and stops; " \
                        "mode \"trace\" is the single-action behaviour — put the trace in the next step")
    end

    validator = STEP_VALIDATORS[kind]
    return unless validator

    probe = step_probe(step, handed: handed)
    probe.send(validator)
    probe.errors.full_messages.each { |message| errors.add(:base, "step #{number}: #{message}") }
  end

  # Where a step's input file comes from, and whether it can come from there at
  # all. A step that needs a file and can get one from nowhere is refused here,
  # by index, rather than posted with no input and discovered as an empty run.
  def validate_step_handoff(step, number, kind, previous, handed: false)
    declared = step["input"].to_s.strip.downcase
    if declared.present? && !STEP_INPUTS.include?(declared)
      return errors.add(:base,
                        "step #{number}: input must be #{STEP_INPUTS.map { |i| %("#{i}") }.join(' or ')}")
    end

    rules = self.class.file_rules_for(step)

    unless handed
      # A compose step is filed against an svg runner but traces nothing: its
      # layers name their own sources, so "needs an artwork source" does not
      # apply to it.
      if kind == "svg" && !self.class.compose_step?(step)
        # THREE situations reach here, and they need different answers: nothing
        # to trace at all; an earlier step that produced something the trace
        # stage cannot read (the confusing one — the operator can see a step
        # above); and the job's OWN artwork being unreadable, which is how a
        # vector-flattened composite reached the runner.
        if previous.present? && produced_extension(previous).present?
          errors.add(:base, "step #{number}: a SVG step traces a RASTER, and step #{number - 1} " \
                            "produces #{produced_extension(previous)}. Add a step that renders the " \
                            "drawing to PNG first (bp's blender operation does), or run the trace " \
                            "as its own job against a rendered file.")
        elsif input_path.to_s.strip.present? && !raster_source?(input_path)
          errors.add(:base, "step #{number}: #{trace_source_refusal(input_path)}")
        elsif input_path.to_s.strip.blank?
          errors.add(:base, "step #{number}: a SVG step needs an artwork source, and this job has none " \
                            "(no artwork, and no earlier step that produces one)")
        end
      end
      return
    end

    return errors.add(:base, "step #{number}: there is no step before it to hand a file from") if previous.blank?

    if rules[:accepts].empty?
      return errors.add(:base,
                        "step #{number}: a #{kind.upcase} step takes a document, not a file — the #{kind} " \
                        "operation has no file input, so step #{number - 1}'s output cannot be handed to it")
    end
    return if previous_produces?(previous, rules[:accepts])

    # The remedy is named where there IS one, because the mismatch that matters
    # (an SVG drawing handed to the trace stage) is otherwise a dead end the
    # operator has to reason out from two extension lists.
    remedy = if kind == "svg" && produced_extension(previous) == ".svg"
               " — the trace stage preps a raster and cannot read an SVG, so render it to " \
               "PNG first (a bp blender step does) or trace a rendered file as its own job"
             else
               ""
             end
    errors.add(:base, "step #{number}: a #{kind.upcase} step takes " \
                      "#{rules[:accepts].join(' / ')} from step #{number - 1}, which produces " \
                      "#{produced_extension(previous).presence || 'nothing'}#{remedy}")
  end

  def previous_produces?(previous, accepts)
    extension = produced_extension(previous)
    extension.present? && accepts.include?(extension)
  end

  # Almost always the kind's own static answer, but a BP step is ONE action whose
  # output depends on the operation it was asked for, so its extension is read
  # off that step's own op rather than guessed from the kind. A compose step is
  # the same shape of answer for the same reason.
  def produced_extension(step)
    return nil unless step.is_a?(Hash)
    return COMPOSE_STEP_RULES[:produces] if self.class.compose_step?(step)

    kind = self.class.runner_kind(step["runner"])
    if kind == "bp"
      op = step["bp"].is_a?(Hash) ? step["bp"]["op"].to_s.strip : ""
      return op == "blender" ? ".png" : ".svg"
    end
    STEP_FILE_RULES.dig(kind, :produces)
  end

  before_create :set_defaults

  scope :recent, -> { order(created_at: :desc) }

  def in_flight?
    IN_FLIGHT_STATES.include?(state)
  end

  # ------------------------------------------------------------------ stranded
  #
  # A row that is `running` with NO runner job behind it can never settle, and
  # nothing in the stack can move it. That is the whole defect, and it is a real
  # measured one: `RunJob#perform` sets `running` the moment the worker picks
  # the job up, and only LATER does a pipeline/flux step dispatch to a runner and
  # write `runner_job_id`. Anything that interrupts the worker in between -- a
  # restart, a killed process, an interrupted demo -- leaves the row stranded,
  # and then:
  #
  #   * `sync_from_runner!` returns immediately (`return unless runner_job_id`),
  #     so the index and show pages have nothing to poll;
  #   * the job list shows a run in progress that will never finish, with
  #     nothing to click that would notice;
  #   * the only remedy is the operator's own Cancel, by hand.
  #
  # `running` is therefore NOT a claim that something is working. It is a claim
  # that the worker STARTED, and until a runner job exists the honest question
  # is whether it got as far as dispatching anything.
  #
  # `started_at` is the anchor rather than `updated_at`, because `sync_from_runner!`
  # and the prep line both write `updated_at` on a healthy row: anchoring on it
  # would reset the clock on every poll and nothing would ever look stranded.
  STUCK_RUNNING_AFTER = 15.minutes

  # True for a row that CLAIMS to be running, has nothing to poll, and has been
  # that way long enough that "the worker is between marking and dispatching" is
  # no longer the honest reading.
  #
  # `pending` and `queued` are deliberately NOT included: a queued row with no
  # runner job is a row that has not been picked up yet, which is exactly what
  # queued means, and a queue can legitimately hold one for a long time. It is
  # specifically `running` -- the state that means "the worker has this" -- that
  # is a claim the row cannot back up.
  def stranded?
    return false unless state == "running"
    return false if runner_job_id.present?
    # A chain between steps has the column blank while a real runner job exists,
    # because `runner_job_id` is whichever step dispatched LAST. Asking the
    # recorded steps rather than gating on `sequenced?` covers both: a chain that
    # is mid-flight, and a single-action job whose step recorded an id under a
    # different path.
    return false if steps_recorded.any? { |e| e.is_a?(Hash) && e["runner_job_id"].present? }

    reference = started_at || created_at
    reference.present? && reference < STUCK_RUNNING_AFTER.ago
  end

  # Why a stranded row is stranded, in the operator's terms, and derived rather
  # than stored. A row that cannot be settled must be able to SAY that, because
  # the defect is precisely that it currently says "running" and means neither.
  def stranded_reason
    return nil unless stranded?
    self.class.stranded_reason_for(self)
  end

  # Reap every stranded row this scope can see, naming the reason. Unscoped
  # scope: the stranded row is invisible by definition, so an owner-scoped sweep
  # would only ever find it if that operator happened to be looking -- and the
  # point is that nobody was looking. Idempotent (the query only matches
  # `running`), and it writes `update_columns` rather than `update!` for the same
  # reason `fail_job` does: a job row that has failed to validate or whose
  # callbacks would now throw must still be recordable, or the failure nobody can
  # see is nobody's problem.
  #
  # Returns the ids it reaped, so a caller can log them rather than discovering
  # later that something changed.
  def self.reap_stranded!(now: Time.current)
    cutoff = STUCK_RUNNING_AFTER.ago(now)
    # The predicate is the SQL SPELLING of `stranded?`, and the two must agree
    # exactly. They did not at first: `stranded?` anchors on `started_at ||
    # created_at`, while the query read `started_at` alone -- so a row the worker
    # marked `running` in the last second and had not yet stamped (a real,
    # normal, sub-second window) was reaped immediately, and the jobs-grid test
    # lost its cancel button on a job that had just been created.
    #
    # So the anchor is spelled out rather than assumed: the row is stranded when
    # EITHER timestamp is present and past the cutoff, and a row with NEITHER is
    # not (there is nothing to measure against, and `created_at` is NOT NULL in
    # practice, so this is the defensive branch rather than the common one).
    stranded = unscoped
                   .where(state: "running")
                   .where(runner_job_id: [nil, ""])
                   .where("(COALESCE(started_at, created_at)) < ?", cutoff)
                   .to_a
    return [] if stranded.empty?

    stranded.each do |job|
      job.update_columns(
        state: "error",
        error: stranded_reason_for(job, now),
        finished_at: now
      )
    end
    stranded.map(&:id)
  end

  # The sentence, built here rather than through the instance so the class-level
  # sweep and the view agree word for word without one calling the other.
  def self.stranded_reason_for(job, now = Time.current)
    "no runner job was ever created for this run — the worker took it and stopped " \
    "before it dispatched anything, so nothing can report back on it and no " \
    "amount of waiting will finish it (running for #{age_in_words(job.started_at || job.created_at, now)}, " \
    "nothing at the runner)"
  end

  # ActiveSupport::Duration#inspect is "15.minutes"; what an operator needs is
  # "11 hours". Deliberately coarse: this is a sentence on a page, and a precise
  # "11 hours 3 minutes" implies a precision the reaper's own threshold does not
  # have.
  def self.age_in_words(time, now = Time.current)
    return "an unknown time" if time.blank?
    seconds = (now - time).to_i
    return "#{seconds}s" if seconds < 60
    return "#{seconds / 60}m" if seconds < 3600
    return "#{seconds / 3600}h" if seconds < 86_400
    "#{(seconds / 86_400).to_i}d"
  end

  # The runner that actually RUNS this job and holds its files.
  #
  # For a flux job that is not the generator. The generator produces one raster
  # and has no job state, no candidates, no archive and no validations; the
  # pipeline that traces that raster runs on the hand-off runner. Every URL this
  # job builds — candidate files, archive, cancel, validations — belongs to the
  # hand-off runner, so this method is the one place that has to know it, and
  # every existing call site is correct without knowing anything.
  def base_url
    self.class.runners.fetch(execution_runner) { raise "unknown runner #{execution_runner}" }
  end

  def execution_runner
    # A sequenced job's runner-facing identity is its PIPELINE step: that is the
    # runner that traced the chain's work, so its candidates, files and archive
    # are what every URL this job builds has to point at. Before a chain has
    # posted one, the job's own label answers, exactly as before.
    if sequenced? && (label = pipeline_step_runner)
      return label
    end
    return runner unless flux?
    handoff = spec.is_a?(Hash) ? spec.dig("flux", "handoff").presence : nil
    handoff || self.class.handoff_runner || runner
  end

  # Where the raster comes from: the generator, which is the label this job was
  # filed against. Only meaningful on a flux job.
  def generator_base_url
    self.class.runners.fetch(runner) { raise "unknown runner #{runner}" }
  end

  def flux?
    self.class.flux_runner?(runner)
  end

  def plot?
    self.class.plot_runner?(runner)
  end

  def blender?
    self.class.blender_runner?(runner)
  end

  # A flux job's generation settings travel in the SPEC, which is already the
  # thing the studio edits and posts — so adding a prompt, a size and a mode
  # needs no migration, and the JSON page can build the same block by hand.
  def flux_config
    block = spec.is_a?(Hash) ? spec["flux"] : nil
    block.is_a?(Hash) ? block : {}
  end

  def flux_prompt
    flux_config["prompt"].to_s.strip
  end

  # "trace" (the default) runs the generated raster through the pipeline like any
  # other source — that is the whole point of handing it to a runner. "raster"
  # stops at the generated image, for when the picture IS the deliverable.
  def flux_mode
    flux_config["mode"].to_s == "raster" ? "raster" : "trace"
  end

  def raster_only?
    flux? && flux_mode == "raster"
  end

  # A plot job's request travels in the SPEC, exactly as a flux job's does: the
  # operation, the document it draws, and -- for a query -- the run records. The
  # rendered output is written back under the same block, so one record carries
  # both the ask and the answer and the job page reads one place.
  def plot_config
    block = spec.is_a?(Hash) ? spec["plot"] : nil
    block.is_a?(Hash) ? block : {}
  end

  def plot_op
    plot_config["op"].to_s.strip
  end

  # The document the operation draws: a geometry spec for generate, a chart spec
  # for digest and query. Nil when there is not one -- which is exactly what the
  # validation refuses on.
  def plot_doc
    doc = plot_config["doc"]
    doc.is_a?(Hash) ? doc : nil
  end

  # The run records a query draws across, or [] when the spec carries none.
  def plot_runs
    runs = plot_config["runs"]
    runs.is_a?(Array) ? runs : []
  end

  # Where the drawn SVG landed (a storage/uploads basename), or nil until the
  # job has run. The job page serves it through the login-gated upload_preview
  # route rather than a new public path.
  def plot_output_file
    rendered = plot_config["rendered"]
    return nil unless rendered.is_a?(Hash)
    rendered["file"].presence
  end

  # A blender job's request travels in the SPEC exactly as a plot job's does --
  # one geometry document -- and the render facts are written back under the
  # same block, so one record carries both the ask and the answer.
  def blender_config
    block = spec.is_a?(Hash) ? spec["blender"] : nil
    block.is_a?(Hash) ? block : {}
  end

  # The document the render is of: a geometry spec carrying an `elements` list
  # (optionally with `tiling`, `extrude`, `render` and `export` blocks). Nil
  # when there is not one -- which is exactly what the validation refuses on.
  def blender_doc
    doc = blender_config["doc"]
    doc.is_a?(Hash) ? doc : nil
  end

  # The `views` the document asks for, as an integer: 1 (the default, one
  # rendered frame back as image/png) or more (a JSON frames manifest).
  def blender_views
    render_block = blender_doc && blender_doc["render"]
    views = render_block.is_a?(Hash) ? render_block["views"] : nil
    views.to_i.positive? ? views.to_i : 1
  end

  # Where the rendered frame landed (a storage/uploads basename), or nil until
  # the job has run. Served through the login-gated upload_preview route, the
  # same route a plot job's SVG and a flux variation use.
  def blender_output_file
    rendered = blender_config["rendered"]
    return nil unless rendered.is_a?(Hash)
    rendered["file"].presence
  end

  # Every frame the render stored, the primary first. A single-view render has
  # one; a multi-view render keeps the whole set, because its manifest named
  # them and a job that threw them away would have to ask the service again.
  def blender_frames
    rendered = blender_config["rendered"]
    files = rendered.is_a?(Hash) ? rendered["files"] : nil
    files.is_a?(Array) ? files : []
  end

  # --- the BP action: one target, six operations ----------------------------
  #
  # A bp job's request travels in the SPEC under `spec["bp"]`, exactly as a plot
  # or blender job's does, and the answer is written back under the same block —
  # so one record carries both the ask and the result, which is what lets the job
  # page read one place regardless of which of the six operations ran.
  #
  #   { "bp" => { "op" => "blender", "doc" => { "elements" => [...] } } }
  #   { "bp" => { "op" => "query", "doc" => {...}, "runs" => [ ... ] } }
  #
  # `runs` is the drawing operations' transport field, so it sits beside `doc`
  # and is sent only for `query`.
  def bp?
    self.class.bp_runner?(runner)
  end

  def bp_config
    block = spec.is_a?(Hash) ? spec["bp"] : nil
    block.is_a?(Hash) ? block : {}
  end

  def bp_op
    bp_config["op"].to_s.strip
  end

  def bp_blender?
    bp_op == "blender"
  end

  def bp_doc
    doc = bp_config["doc"]
    doc.is_a?(Hash) ? doc : nil
  end

  def bp_runs
    runs = bp_config["runs"]
    runs.is_a?(Array) ? runs : []
  end

  def bp_output_file
    rendered = bp_config["rendered"]
    return nil unless rendered.is_a?(Hash)
    rendered["file"].presence
  end

  def bp_frames
    rendered = bp_config["rendered"]
    files = rendered.is_a?(Hash) ? rendered["files"] : nil
    files.is_a?(Array) ? files : []
  end

  # The generated variations this job holds, as a list of per-image facts with a
  # local `file` (a storage/uploads basename) each. A batch (images > 1) stores
  # every one; a single generation stores one. Falls back to the primary raster
  # for jobs created before variations were recorded. Empty for a non-flux job.
  def flux_variations
    return [] unless flux?
    recorded = generated_variations
    return recorded if recorded.any?
    input_path.present? ? [{ "file" => File.basename(input_path.to_s) }] : []
  end

  # #job-generated-variations
  # The generated raster files this job holds, read from the job's OWN RECORD
  # (`spec["flux"]`) and never through the runner kind.
  #
  # The distinction matters for anything that COUNTS them: `flux?` asks
  # "is a generator wired on THIS deployment", which is configuration, while
  # these images are data the run produced. A tally that went through the kind
  # would report zero generated files on a box whose flux runner line was
  # removed from the environment — a page lying about its own database. So the
  # shape rule lives here, once, and the kind-gated reader above uses it.
  def generated_variations
    return [] unless spec.is_a?(Hash) && spec["flux"].is_a?(Hash)
    images = spec.dig("flux", "rendered", "images")
    return images if images.is_a?(Array) && images.any?
    input_path.present? ? [{ "file" => File.basename(input_path.to_s) }] : []
  end

  # The colour-inverted twin of this job's raster as a LOCAL storage/uploads
  # basename, or nil when the studio has not made one.
  #
  # Only a raster-only flux job has one HERE: it has no pipeline runner, so
  # nothing produces the source.inverse.png a trace-mode job's prep stage writes,
  # and the twin is inverted from the raster when the raster lands (RunJob,
  # FluxInverseTwin) and recorded with the other render facts. A trace-mode job's
  # twin lives on the runner and is reached as source.inverse.png through the
  # file proxy, so this is nil for it by design, not by failure.
  def flux_inverse_file
    return nil unless flux?
    rendered = spec.is_a?(Hash) ? spec.dig("flux", "rendered") : nil
    return nil unless rendered.is_a?(Hash)
    name = rendered["inverse"].to_s
    name.match?(/\A[\w.\-]+\z/) ? name : nil
  end

  # The reference image an img2img generation was made from: a storage/uploads
  # basename the service read through /edit, or nil for a plain text-to-image
  # generation. Only the BASENAME is honoured — the spec is user-editable text
  # and a stored upload is the only thing a reference may resolve to.
  def flux_reference_file
    return nil unless flux?
    name = flux_config["image"].to_s.strip
    return nil if name.blank?
    base = File.basename(name)
    base.match?(/\A[\w.\-]+\z/) ? base : nil
  end

  # The complete generation config the preview popup reveals, as one hash — the
  # request the job stored (spec.flux) merged with the render facts recorded for
  # this variation, so a batch's per-image seed and size win over the request's
  # and the popup can never disagree with the tile it was opened from. Blank
  # keys are dropped rather than shown as empty.
  #
  # nil for anything that is not a flux job: a traced candidate has no
  # generation behind it, and that is what keeps the control off its popup.
  def flux_reveal_config(variation = nil)
    return nil unless flux?
    v = variation.is_a?(Hash) ? variation : {}
    cfg = flux_config
    variations = flux_variations
    images = cfg["images"].presence
    images ||= variations.size if variations.any?

    {
      "mode" => flux_mode,
      "model" => v["model"] || cfg["model"],
      "width" => v["width"] || cfg["width"],
      "height" => v["height"] || cfg["height"],
      "steps" => cfg["steps"],
      "guidance" => cfg["guidance"],
      "seed" => v["seed"] || cfg["seed"],
      "images" => images,
      "negative_prompt" => cfg["negative_prompt"],
      "strength" => cfg["strength"],
      "seconds" => v["seconds"],
      "reference" => flux_reference_file
    }.reject { |_key, value| value.nil? || value.to_s.strip.empty? }
  end

  # --- the COMPOSE job: a composite that has been flattened -------------------
  #
  # A composite is composed by the STUDIO (it POSTs the merged document to the
  # pipeline runner's /compose and stores the answer), so the work is real and
  # its result is real -- but until now it lived only as a Composite row plus a
  # scrapbook item, so it appeared NOWHERE in the Jobs history and clicking its
  # image led to no results page. A flattened composite now records a Job: the
  # same lineage every other run has (a name, an owner, a state, a preview, a
  # page), filed against the runner that actually performed the merge.
  #
  # `runner` is the real pipeline runner's LABEL, not a new kind: /compose IS
  # that runner's route, so the Runner column tells the truth, and a client that
  # understands the runner contract is not handed a label it cannot resolve.
  # What marks it is the spec block, which is the one place the ask and the
  # answer both live -- exactly as a plot or bp job's own block does.
  COMPOSE_SPEC_KEY = "compose".freeze

  def compose?
    spec.is_a?(Hash) && spec[COMPOSE_SPEC_KEY].is_a?(Hash)
  end

  def compose_config
    compose? ? spec[COMPOSE_SPEC_KEY] : {}
  end

  # The published SVG/PNG the flatten stored (a storage/uploads basename), or nil
  # until one lands. Local, like a plot drawing: served through upload_preview.
  def compose_output_file
    compose_config["rendered"].is_a?(Hash) ? compose_config.dig("rendered", "file").presence : nil
  end

  # The mode the flatten ran in. Stored BOTH at the top level (what the merge
  # was) and under `rendered` (what the artefact is); read either, so a job
  # written by an older or hand-made spec still answers.
  def compose_mode
    (compose_config["mode"].presence || compose_config.dig("rendered", "mode")).presence
  end

  def compose_composite_id
    compose_config["composite_id"]
  end

  # The layers the composite held, as the compose spec saw them -- the provenance
  # a reader needs to say what this artefact is MADE of. Counted, never stored
  # twice: the composite is the record, this is its shape at flatten time.
  def compose_layer_count
    layers = compose_config["layers"]
    layers.is_a?(Array) ? layers.size : 0
  end

  # A compose job never dispatched anything, so there is no runner job to proxy:
  # its archive, its dataset and its files are all local. Every URL-building
  # action asks this first rather than building a path with a nil runner id.
  def locally_produced?
    compose?
  end

  # The runner-side filename of THIS job's top candidate, or nil when it has no
  # candidates yet. The comparison's list arrives ranked, so the first entry is
  # the one the operator is being asked to pick. Carried by a pipeline job and by
  # a flux TRACE job; a flux RASTER-ONLY or plot job has no comparison to read.
  #
  # NOT what previews the row any more: the thumbnail shows the run's colour
  # source (or its finished proof). Kept because "which candidate is first" is a
  # real question other readers ask.
  def top_candidate_file
    list = comparison.is_a?(Hash) ? Array(comparison["candidates"]) : []
    entry = list.first
    entry.is_a?(Hash) ? entry["file"].to_s.strip.presence : nil
  end

  # The preview PNG of the most recent FINISHED proof this job carries, as the
  # runner published it -- its own manifest names the file. A job can be picked
  # through to a proof more than once, so the row shows what the operator last
  # committed to. Nil while no proof has finished, and nil for a manifest that
  # carries no render.
  def proof_preview_file
    done = validations.select { |v| v.state == "done" }.last
    manifest = done && done.manifest
    manifest.is_a?(Hash) ? manifest["proof"].to_s.strip.presence : nil
  end

  # The one image that previews this job on the Jobs index.
  #
  # The DEFAULT is the run's COLOUR SOURCE: the raster the sweep was fed --
  # `source.png`, the stable name a runner publishes beside its inverted twin --
  # or, for a kind with no raster behind it, the thing it drew or generated. A
  # FINISHED PROOF supersedes it: once a pick has been proved, the proof IS the
  # run's result, so its PNG becomes the preview the operator recognises the row
  # by. Nil when the job has produced nothing to show yet (a queued
  # flux/plot/blender job), so the thumbnail cell degrades to the placeholder
  # instead of a broken image.
  #
  # The `return` on each kind line is load-bearing: a queued PLOT job answers nil
  # rather than falling through to the source name, so the cell stays empty
  # instead of requesting a file its runner will never have.
  def preview_file
    return proof_preview_file if proof_preview_file.present?
    return compose_output_file if compose?
    return bp_output_file if bp?
    return plot_output_file if plot?
    return blender_output_file if blender?
    return flux_variations.dig(0, "file") if flux? && runner_job_id.blank?
    "source.png"
  end

  # Whether the preview file lives in storage/uploads (a raster-only flux job's
  # generated variation, a plot/blender/bp output) or on the runner (a finished
  # proof's PNG, or a pipeline job's source.png) -- the two routes differ, so the
  # view needs this to build the right URL.
  #
  # A proof ALWAYS comes from the runner, and so does source.png, so both answer
  # false even on a flux job, where the generated raster would otherwise route to
  # upload_preview.
  def preview_from_upload?
    return false if proof_preview_file.present?
    return true if compose? || bp? || plot? || blender?
    flux? && runner_job_id.blank?
  end

  def sync_from_runner!
    return unless runner_job_id
    data = RunnerClient.get_job(self)

    # A STEP's runner job is not the CHAIN's verdict, and `runner_job_id` is not
    # a chain's own -- it names whichever step LAST dispatched to a runner and
    # stays set after that step finished. For a step list the job's state, its
    # activity line and its error belong to the chain (`perform` -> running,
    # `fail_step!` -> error, `complete_chain!` -> done, which writes "the
    # chain's own verdict last so it is the one that stands"). Mirroring them
    # here broke exactly that: MEASURED on a 7-step chain whose step 1 was the
    # trace -- the page's own `sync_from_runner!` (the show action above, and
    # the index's in-flight sweep) fired while step 7 was still rendering,
    # adopted the TRACE runner's "done", and the job read done with
    # `finished_at` nil and step 7 recorded running, with the chain's verdict
    # never written at all. The FACTS below still mirror; the verdict does not.
    unless sequenced?
      self.state = data[:state] if data[:state]
      self.prep_summary = data[:prep_summary] if data[:prep_summary]
      self.error = data[:error] if data.key?(:error)
    end

    self.candidate_count = data[:candidate_count].to_i
    self.comparison = data[:comparison] if data[:comparison]
    save!

    # sync candidates when the comparison arrives
    if comparison.is_a?(Hash) && (list = comparison["candidates"])
      existing = candidates.index_by(&:file)
      list.each do |c|
        rec = existing[c["file"]] || candidates.build
        rec.file = c["file"]
        rec.preset = c.dig("sweep", "preset")
        rec.hierarchical = c.dig("sweep", "hierarchical")
        rec.filter_speckle = c.dig("sweep", "filter_speckle")
        rec.use_palette = c.dig("sweep", "use_palette")
        rec.sweep = c["sweep"]
        rec.layer_a = c.dig("layer_a", "status")
        rec.layer_b = c.dig("layer_b", "status")
        rec.hard = c["hard"].to_i
        rec.advisory = c["advisory"].to_i
        rec.fidelity = c["fidelity"]
        rec.passed = c["passed"]
        rec.save!
      end
    end
    self
  end

  def passed_count
    return 0 unless comparison.is_a?(Hash)
    Array(comparison["candidates"]).count { |c| c["passed"] }
  end

  # The runner's comparison entries never carry a "fidelity_verdict" -- the
  # keys are file, sweep, layer_a, layer_b, hard, advisory, fidelity, passed --
  # so the verdict shown in the candidates table AND in the findings popup has
  # to be derived from the fidelity numbers themselves. Done here, once, so both
  # surfaces agree. An explicit verdict, if a runner ever sends one, still wins.
  def self.fidelity_verdict(entry)
    # A runner-supplied verdict is trusted verbatim, but it has to be a String:
    # the view calls fv.tr("_", " "), which would raise NoMethodError on a
    # number. Coerced here, once.
    explicit = entry.is_a?(Hash) ? entry["fidelity_verdict"] : nil
    return explicit.to_s if explicit.present?

    f = entry.is_a?(Hash) ? entry["fidelity"] : nil
    return "unmeasured" unless f.is_a?(Hash) && f["measured"]
    mae = f["mae_art"]
    return "unmeasured" if mae.nil?

    mae = mae.to_f
    return "faithful" if mae <= 25
    return "drift" if mae <= 60
    "lost"
  end

  # The pill class behind a verdict; the table cell and the popup pill share it.
  def self.fidelity_status(verdict)
    case verdict
    when "faithful" then "pass"
    when "drift"    then "warn"
    when "lost"     then "fail"
    else                 "pending"
    end
  end

  # Decorate each comparison candidate with the derived verdict AT READ TIME.
  # The findings popup is fed the raw comparison entry by the JSON endpoint and
  # the model cannot reach into that response from the controller, so the
  # derivation has to ride on the entry itself for the popup and the table to
  # share one implementation rather than growing a second copy in the view's JS.
  def comparison
    raw = read_attribute(:comparison)
    return raw unless raw.is_a?(Hash) && raw["candidates"].is_a?(Array)
    raw.merge(
      "candidates" => raw["candidates"].map do |c|
        next c unless c.is_a?(Hash)
        verdict = self.class.fidelity_verdict(c)
        c.merge(
          "fidelity_verdict" => verdict,
          "fidelity_status" => self.class.fidelity_status(verdict)
        )
      end
    )
  end

  def file_url(name)
    "#{base_url}/files/#{runner_job_id}/#{name}"
  end

  def archive_url
    "#{base_url}/jobs/#{runner_job_id}/archive"
  end

  private

  # One step, in the shape every reader handles: a resolved runner label, the
  # kind's own block, and the input declaration when the step makes one.
  def normalize_step(step)
    raw = step.is_a?(Hash) ? step.deep_stringify_keys : {}
    label = raw["runner"].to_s.strip.downcase
    kind = self.class.runner_kind(label)
    out = { "runner" => label, kind => normalize_step_block(kind, raw[kind]) }
    declared = raw["input"].to_s.strip.downcase
    out["input"] = declared if declared.present?
    # The operation travels with the step, beside the label where it was
    # declared. Dropped when it is not a known one rather than carried through:
    # validation refuses an unknown op, and a normalised list that kept it would
    # let a reader act on an operation nothing implements.
    op = raw["op"].to_s.strip.downcase
    out["op"] = op if STEP_OPS.include?(op)
    out
  end

  # A document runner's document — or a query's run records — may arrive as a
  # JSON STRING, exactly as a single-action job's may (the form parses it, an
  # agent or a hand-edited contract may paste it), so it is parsed once here,
  # where validation, the worker and a page all read it. A string that does not
  # parse is left as it was and the kind's own validator refuses the step with
  # the reason.
  def normalize_step_block(kind, block)
    doc = block.is_a?(Hash) ? block.deep_stringify_keys : {}
    # `bp` belongs in this list for the same reason the other two do: its `doc`
    # and `runs` arrive as JSON strings from an agent or a hand-edited contract,
    # and a step whose document stayed a string was refused as if it had none.
    return doc unless %w[plot blender bp].include?(kind)
    %w[doc runs].each do |key|
      value = doc[key]
      next unless value.is_a?(String) && value.present?
      begin
        doc[key] = JSON.parse(value)
      rescue JSON::ParserError
        nil
      end
    end
    doc
  end

  # A throwaway, UNSAVED job carrying one step's block, so the step's kind
  # validators run on the very code a single-action job runs — the accessors
  # (flux_prompt, plot_op, blender_doc) read exactly as they do on a real job.
  # Never saved, never enqueued: it exists for the length of one validation.
  #
  # A BLEND step that is handed a file is a special case, and the honest one:
  # its geometry comes from the SVG it is handed, converted at run time, so the
  # probe carries the document it will ACTUALLY render — its own block with a
  # stand-in elements list — rather than being refused for the elements the
  # hand-off supplies. Everything else the kind requires (a document at all)
  # still holds.
  def step_probe(step, handed: false)
    raw = step.is_a?(Hash) ? step : {}
    label = raw["runner"].to_s.strip.downcase
    kind = self.class.runner_kind(label)
    block = raw[kind].is_a?(Hash) ? raw[kind].deep_dup : {}

    # A step that RENDERS GEOMETRY is handed a file by having that file turned
    # into elements, so its document must satisfy the `elements` requirement the
    # validator checks — whether it is the legacy blender kind or the blender
    # OPERATION of a bp step, which is the same code path under one action now.
    renders_geometry = kind == "blender" ||
                       (kind == "bp" && block["op"].to_s.strip == "blender")
    if handed && renders_geometry
      doc = block["doc"].is_a?(Hash) ? block["doc"].deep_dup : {}
      doc["elements"] = ["handed"] if Array(doc["elements"]).empty?
      block["doc"] = doc
    end

    Job.new(name: name.presence || "step", runner: label, source_kind: source_kind,
            input_path: input_path, spec: { kind => block })
  end

  def set_defaults
    self.stem ||= begin
      s = name.to_s.downcase.gsub(/[^a-z0-9]+/, "-")
      s = s.split("-").reject(&:blank?).join("-")
      s.presence || "artwork"
    end
    self.spec ||= {}
  end
end
