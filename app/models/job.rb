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

  # A runner's KIND says what it DOES, not where it is. Three exist:
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
  #
  # flux and plot are both Run Job TARGETS but neither is a PIPELINE runner: they
  # trace nothing, hold no job state and have no candidates, so neither may ever
  # be offered as a hand-off target. What separates them is where the work
  # happens — flux draws a raster for the pipeline to trace, plot draws one SVG
  # that IS the deliverable — and that difference lives in the view and in
  # RunJob, never in the runner contract.
  #
  # The default is "svg", so a deployment that sets only _URL keeps working
  # exactly as before and nothing must be renamed to stay correct. That also
  # means an existing label (a host-named one, say) is still a pipeline runner
  # without anyone touching it.
  RUNNER_KIND_RE = /\ACHOPSHOP_RUNNER_[A-Z0-9_]+_KIND\z/.freeze
  RUNNER_KINDS = %w[svg flux plot].freeze

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

  # The runners a JOB can be filed against: one that traces (svg), one that
  # generates a raster to trace (flux), or one that draws a document to keep
  # (plot). All three are Run Job targets now -- the form switches its fields on
  # the runner's kind, and the plot kind has a panel of its own (an operation
  # plus the JSON document it draws). Stated positively, like pipeline_runners,
  # so a new kind is opted IN deliberately -- and note that being a job target is
  # a DIFFERENT question from being a pipeline runner: a plot runner is the
  # former and never the latter.
  JOB_KINDS = %w[svg flux plot].freeze

  def self.job_runners
    runner_urls.keys.select { |label| JOB_KINDS.include?(runner_kind(label)) }
  end

  # The three operations chopshop-plot's serve surface exposes, and the only
  # values a plot job's spec["plot"]["op"] may carry. Named once here so the
  # model, the form and the worker all read the same list.
  PLOT_OPS = %w[generate digest query].freeze

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

  validates :name, presence: true
  # A lambda, not a snapshot: the runner list is env-driven and can grow at
  # runtime, so the validation has to ask the same question the form does.
  validates :runner, inclusion: { in: ->(_job) { runners.keys } }

  # A flux job's one required input. The service refuses an empty prompt itself,
  # but a round trip to a GPU box to be told that is a poor way to find out.
  validate :flux_job_needs_a_prompt

  def flux_job_needs_a_prompt
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
    return unless plot?
    unless PLOT_OPS.include?(plot_op)
      errors.add(:base, "a PLOT job needs an operation: one of #{PLOT_OPS.join(', ')}")
    end
    errors.add(:base, "a PLOT job needs a document to draw") unless plot_doc
    if plot_op == "query" && plot_runs.empty?
      errors.add(:base, "a PLOT query needs run records")
    end
  end

  before_create :set_defaults

  scope :recent, -> { order(created_at: :desc) }

  def in_flight?
    IN_FLIGHT_STATES.include?(state)
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

  # The generated variations this job holds, as a list of per-image facts with a
  # local `file` (a storage/uploads basename) each. A batch (images > 1) stores
  # every one; a single generation stores one. Falls back to the primary raster
  # for jobs created before variations were recorded. Empty for a non-flux job.
  def flux_variations
    return [] unless flux?
    images = spec.is_a?(Hash) ? spec.dig("flux", "rendered", "images") : nil
    if images.is_a?(Array) && images.any?
      images
    elsif input_path.present?
      [{ "file" => File.basename(input_path.to_s) }]
    else
      []
    end
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

  # The runner-side filename of THIS job's top candidate, or nil when it has no
  # candidates yet. The comparison's list arrives ranked, so the first entry is
  # the one the operator is being asked to pick -- which is exactly what a row
  # waiting for proofs should show, and a more meaningful thumbnail than the raw
  # raster every candidate was traced from. Carried by a pipeline job and by a
  # flux TRACE job; a flux RASTER-ONLY or plot job has no comparison to read.
  def top_candidate_file
    list = comparison.is_a?(Hash) ? Array(comparison["candidates"]) : []
    entry = list.first
    entry.is_a?(Hash) ? entry["file"].to_s.strip.presence : nil
  end

  # The one image that previews this job on the Jobs index: the top candidate
  # when there is one, else the drawn SVG for a plot job, the first generated
  # variation for a flux job, or the runner's source.png for a pipeline job.
  # Nil when the job has produced nothing yet (a queued or still-running
  # flux/plot job), so the thumbnail cell degrades to the placeholder instead of
  # a broken image.
  def preview_file
    return top_candidate_file if top_candidate_file.present?
    return plot_output_file if plot?
    return flux_variations.dig(0, "file") if flux?
    "source.png"
  end

  # Whether the preview file lives in storage/uploads (flux and plot, served
  # through the login-gated upload_preview route) or on the runner (a candidate,
  # or a pipeline job's source.png, served through the file proxy). The two
  # routes differ, so the view needs this to build the right URL.
  #
  # A candidate ALWAYS comes from the runner, so it answers false even on a flux
  # job -- where the raster variation would otherwise route to upload_preview.
  def preview_from_upload?
    return false if top_candidate_file.present?
    plot? || flux?
  end

  def sync_from_runner!
    return unless runner_job_id
    data = RunnerClient.get_job(self)
    self.state = data[:state] if data[:state]
    self.prep_summary = data[:prep_summary] if data[:prep_summary]
    self.candidate_count = data[:candidate_count].to_i
    self.comparison = data[:comparison] if data[:comparison]
    self.error = data[:error] if data.key?(:error)
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

  def set_defaults
    self.stem ||= begin
      s = name.to_s.downcase.gsub(/[^a-z0-9]+/, "-")
      s = s.split("-").reject(&:blank?).join("-")
      s.presence || "artwork"
    end
    self.spec ||= {}
  end
end
