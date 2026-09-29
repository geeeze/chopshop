# The single serial gate every job passes through. A flux generation, a plot
# drawing, a blender render and a pipeline run are ALL enqueued here, and Solid
# Queue runs the "runs" queue with exactly one worker thread — so the studio
# never sends more than one job to a runner (or a renderer) at a time.
# Everything else waits in order, and a queued job can be cancelled before its
# turn.
#
# The studio Job record is the source of truth; this job is only the trigger.
# It re-reads the record at the start and aborts if it is no longer "queued"
# (cancelled while waiting). That cooperative check is the backstop behind the
# Solid Queue discard in JobsController#cancel, so a cancelled job can never be
# dispatched even if the discard misses.
class RunJob < ApplicationJob
  queue_as :runs

  # The most QUEUED jobs one user may have waiting behind the one that is
  # running. A job's owner is stamped from the signed-in user (see Owned), so
  # "the queue" is per user: five is one operator's whole allotment, and filling
  # it delays nobody else. Enforced in JobsController#enqueue_run.
  MAX_QUEUE_PER_USER = 5

  # The global backstop behind the per-user cap, so one pathological user (or a
  # bug in the per-user count) still cannot starve the single worker: the box
  # never waits on more than this many jobs in total. Enforced in
  # JobsController#enqueue_run beside the per-user gate.
  MAX_QUEUE = 255

  # Raised when a queue is already at its limit -- one user's
  # MAX_QUEUE_PER_USER, or the global MAX_QUEUE backstop; surfaced to the
  # operator as a form error rather than a silent drop.
  class QueueFull < StandardError; end

  # Reference images are validated here (synchronously, in the controller) so a
  # bad path in the spec is refused before anything is enqueued. The check is
  # the same one the data-URL build re-runs at generation time: only a basename
  # that resolves inside storage/uploads is honoured, never a directory.
  def self.validate_reference!(name)
    uploads = Rails.root.join("storage", "uploads")
    candidate = uploads.join(File.basename(name.to_s))
    unless candidate.file? && candidate.to_s.start_with?(uploads.to_s + File::SEPARATOR)
      raise FluxClient::FluxError,
            "reference image #{File.basename(name.to_s)} is not a stored upload"
    end
    true
  end

  def perform(job_id)
    job = Job.find_by(id: job_id)
    return unless job && job.state == "queued"

    job.update!(state: "running", started_at: Time.current,
                prep_summary: activity_line(job))

    # One serial gate, five kinds of work: a step list, a generator, a drawer,
    # a renderer, or a pipeline runner.
    return run_steps(job) if job.sequenced?
    return run_flux(job) if job.flux?
    return run_bp(job) if job.bp?
    return run_plot(job) if job.plot?
    return run_blender(job) if job.blender?
    run_pipeline(job)
  rescue BpClient::Error => e
    fail_job(job, "BP: #{e.message}")
  rescue FluxClient::FluxError => e
    fail_job(job, "FLUX: #{e.message}")
  rescue PlotClient::PlotError => e
    fail_job(job, "PLOT: #{e.message}")
  rescue BlenderClient::BlenderError => e
    fail_job(job, "BLENDER: #{e.message}")
  rescue RunnerClient::RunnerError => e
    fail_job(job, e.message)
  rescue StandardError => e
    fail_job(job, "runner connection failed: #{e.message}")
  end

  private

  # --- a job whose request is a STEP LIST -----------------------------------
  #
  # A step list (spec["steps"]) is an ordered set of the same per-kind requests
  # a single-action job carries, and THIS is what runs it. The runner side is
  # untouched and stays STATELESS: every runner here serves one operation per
  # request and remembers nothing about what came before, so the chain lives
  # entirely on this side — post step 1, wait for it, post step 2 with step 1's
  # produced file, and so on. That is why no runner needed a change, a session
  # or a chain concept, and why a hand-off the studio cannot derive is refused
  # by the MODEL's validation, by index, instead of being posted blind.
  #
  # The chain stops — without marking anything done — the moment the record is
  # no longer "running": a cancel between steps, or during a step, ends the
  # sequence exactly as it ends a single-action run.

  # How often a pipeline step's runner job is polled, and how long one step may
  # take before the chain gives up on it. A trace is minutes, not seconds, and
  # the next step cannot start until its input exists, so this is a real wait
  # rather than a poll for display.
  STEP_POLL_INTERVAL = 5
  STEP_POLL_TIMEOUT = 1800

  # A runner job that will not change again.
  TERMINAL_RUNNER_STATES = %w[done error cancelled].freeze

  def run_steps(job)
    steps = job.steps
    total = steps.size
    previous = nil

    steps.each_with_index do |step, i|
      number = i + 1
      label = step["runner"]
      kind = Job.runner_kind(label)

      # Cancelled between steps: stop where the chain got to. The record is
      # already in its terminal state; RunJob only has to not continue.
      return if cancelled?(job)

      start_step!(job, number, total, step, kind)
      job.update_columns(prep_summary: "step #{number} of #{total}: #{label} " \
                                       "(#{Job.step_operation(step)})…")

      begin
        fact = run_step(job, step, number, previous)
      rescue StandardError => e
        return fail_step!(job, number, total, step, kind, e.message)
      end

      # Cancelled WHILE this step ran: its work is dropped and the chain stops,
      # the same rule every single-action path follows.
      return if fact.nil?

      previous = fact
      finish_step!(job, number, total, step, kind, fact)
    end

    complete_chain!(job, total)
  end

  # An UNSAVED job carrying one step's block, so every per-kind path below runs
  # exactly as it does for a single-action job: the flux settings reader reads
  # the step's block, PlotClient gets the step's document, the blender document
  # is the step's. Its `runner` is the STEP's label, so anything that resolves a
  # URL from the runner (generator_base_url, and the maps looked up by hand in
  # the step methods) lands on the runner the step names. Never saved, never
  # enqueued: it lives for the length of one step.
  def step_probe(job, step)
    kind = Job.runner_kind(step["runner"])
    Job.new(name: job.name, runner: step["runner"], source_kind: job.source_kind,
            input_path: job.input_path, spec: { kind => step[kind] })
  end

  def run_step(job, step, number, previous)
    kind = Job.runner_kind(step["runner"])
    input = step_input_file(job, step, previous)

    case kind
    when "svg"     then Job.compose_step?(step) ? run_compose_step(job, step, number) : run_pipeline_step(job, step, number, input)
    when "flux"    then run_flux_step(job, step, number, input)
    when "bp"      then run_bp_step(job, step, number, input)
    when "plot"    then run_plot_step(job, step, number)
    when "blender" then run_blender_step(job, step, number, input)
    else                run_pipeline_step(job, step, number, input)
    end
  end

  # The file this step is HANDED, or nil when its kind takes none. An explicit
  # "input" is honoured ("previous" or "job"); otherwise a kind that cannot run
  # without a source takes the step before it when that step produced something
  # it accepts, and the job's own artwork when it did not. Validation has
  # already refused a chain whose hand-off cannot be derived, so reaching the
  # raise below means a chain was created without it.
  def step_input_file(job, step, previous)
    kind = Job.runner_kind(step["runner"])
    rules = Job.file_rules_for(step)
    declared = step["input"].to_s.strip.downcase
    from_previous = declared == "previous" ||
                    (declared.blank? && rules[:needs] && previous && rules[:accepts].include?(previous["ext"].to_s))

    if from_previous
      if rules[:accepts].empty?
        raise RunnerClient::RunnerError,
              "the #{kind} operation has no file input to hand a file to"
      end
      return previous["path"] if previous && previous["path"].present?
      raise RunnerClient::RunnerError,
            "the step before it produced no file to hand over"
    end

    return nil unless rules[:needs]

    job.input_path.to_s.presence ||
      raise(RunnerClient::RunnerError,
            "needs an artwork source and this job has none")
  end

  # --- one step, per kind --------------------------------------------------

  # A flux step generates a raster and STOPS there: the chain, not the
  # generator, decides what happens to it, so the hand-off to a pipeline runner
  # that a single-action flux job performs never happens inside a step list.
  # The model refuses a flux step that asks for mode "trace" for this reason.
  def run_flux_step(job, step, number, input)
    probe = step_probe(job, step)
    rendered = FluxClient.render(
      Job.runners.fetch(step["runner"]),
      **flux_render_options(probe, reference: input ? FluxClient.data_url(input) : nil)
    )
    return nil if cancelled?(job)

    stored = store_flux_rasters(probe, rendered)
    facts = flux_render_facts(probe, rendered, stored)
    write_step_render!(job, number, "flux", facts)

    step_fact(stored.first, "image/png")
  end

  # A plot step draws its document on the runner the step names — a different
  # label from the job's own is normal here, which is exactly why every call in
  # this section resolves its URL from the STEP.
  def run_plot_step(job, step, number)
    base = Job.runners.fetch(step["runner"])
    probe = step_probe(job, step)
    op = probe.plot_op

    rendered =
      case op
      when "query"  then PlotClient.query(base, probe.plot_runs, probe.plot_doc)
      when "digest" then PlotClient.digest(base, probe.plot_doc)
      else               PlotClient.generate(base, probe.plot_doc)
      end
    return nil if cancelled?(job)

    stored = store_plot_svg(rendered)
    name = File.basename(stored.to_s)
    write_step_render!(job, number, "plot",
                       { "file" => name, "op" => rendered[:op], "content_type" => rendered[:content_type] })

    step_fact(stored, "image/svg+xml")
  end

  # A blender step renders. When it was handed a file, that file is an SVG and
  # it is CONVERTED studio-side into the blend document's own element
  # vocabulary (see blend_elements_from_svg): the blend operation renders
  # geometry and has no file input, so handing a path to it is not a thing the
  # service can do.
  def run_blender_step(job, step, number, input)
    probe = step_probe(job, step)
    doc = (probe.blender_doc || {}).deep_dup
    dropped = []

    if input
      derived, dropped = blend_elements_from_svg(File.binread(input))
      doc["elements"] = Array(doc["elements"]) + derived
      write_step_note!(job, number, "blender",
                       { "document_from" => File.basename(input.to_s),
                         "elements_from_svg" => derived.size,
                         "dropped_attributes" => dropped })
    end

    rendered = BlenderClient.render(Job.runners.fetch(step["runner"]), doc)
    return nil if cancelled?(job)

    stored = store_blender_frames(rendered)
    name = File.basename(stored.first.to_s)
    facts = blender_render_facts(probe, rendered, stored, name)
    write_step_render!(job, number, "blender", facts)

    step_fact(stored.first, "image/png")
  end

  # A COMPOSE step is executed HERE, not on a runner — and that is the whole
  # point of it existing. `/compose` is a route on the pipeline runner, but the
  # work that makes a compose correct is studio-side: every layer's source has to
  # be resolved and INLINED (the runner is on another box and cannot see this
  # app's storage), which is exactly what `ComposeSpec` does for a composite. So
  # a step that declares `op: compose` builds the same wire spec a flattened
  # composite does and POSTs it to that runner's route.
  #
  # A layer may name `step:<n>` — the file an EARLIER step of this SAME chain
  # produced. That is the reason to put composing in a chain at all: the sheet is
  # composed out of the rasters the steps above it generated, in one job, with no
  # hand-off in between. The file is resolved from the ledger (which the worker
  # has already written by the time this step runs), so a step that named a
  # later step, or one that produced nothing, is refused by index rather than
  # composed as a hole.
  def run_compose_step(job, step, number)
    doc = step["svg"].is_a?(Hash) ? step["svg"] : {}
    raw_layers = doc["layers"].is_a?(Array) ? doc["layers"] : []
    layers = raw_layers.map do |layer|
      layer.is_a?(Hash) ? layer.merge("src" => compose_layer_src(job, layer, number)) : layer
    end

    spec = ComposeSpec.build(ComposeDocument.new(
      width: doc["width"], height: doc["height"], background: doc["background"],
      palette: doc["palette"], layers: layers
    ))

    result = ComposeClient.compose(Job.runners.fetch(step["runner"]), spec)
    return nil if cancelled?(job)

    stored = store_step_file(result[:bytes], ".svg")
    write_step_render!(job, number, "svg",
                       { "file" => File.basename(stored.to_s), "operation" => Job::COMPOSE_OP,
                         "mode" => "vector", "layers" => spec["layers"].size,
                         "content_type" => "image/svg+xml" })

    step_fact(stored, "image/svg+xml")
  end

  # A compose layer's source. `step:<n>` is the chain's own hand-off and is
  # resolved here; every other form is passed through untouched for
  # `ComposeSpec.read` to resolve (a data URI, an upload path, a scrapbook item,
  # a runner URL) or to refuse BY NAME, which it already does.
  def compose_layer_src(job, layer, number)
    raw = layer["src"].to_s.strip
    match = raw.match(/\Astep:(\d+)\z/)
    return raw unless match

    index = match[1].to_i
    if index >= number
      raise RunnerClient::RunnerError,
            "step #{number}: layer #{layer_label(layer)} names step #{index}, which does not run " \
            "before it — a compose step composes what the steps ABOVE it produced"
    end

    entry = job.reload.steps_recorded.find { |e| e.is_a?(Hash) && e["index"] == index }
    file = entry.is_a?(Hash) ? entry["file"].to_s.presence : nil
    if file.blank?
      raise RunnerClient::RunnerError,
            "step #{number}: layer #{layer_label(layer)} names step #{index}, which produced no " \
            "file to compose"
    end

    # The stored-upload route ComposeSpec reads a local file through, so nothing
    # here has to know storage/uploads' layout.
    "/jobs/upload_preview/#{File.basename(file)}"
  end

  def layer_label(layer)
    name = layer["name"].to_s.presence || layer["key"].to_s.presence
    name ? "\"#{name}\"" : "?"
  end

  # A pipeline (svg) step dispatches to the runner contract and then WAITS: the
  # step's output becomes the next step's input, so the chain cannot post step 2
  # before this one has finished. The runner is asked where its one job got to —
  # nothing about the chain is sent to it.
  #
  # The candidates the runner produces stay the runner's, but the TOP one is
  # fetched into storage/uploads so a later step can be handed a real file.
  def run_pipeline_step(job, step, number, input)
    label = step["runner"]
    base = Job.runners.fetch(label)
    path = input.presence || job.input_path.to_s.presence
    raise RunnerClient::RunnerError, "a SVG step needs an artwork source and this job has none" if path.blank?

    spec = step["svg"].is_a?(Hash) ? step["svg"] : {}
    resp = RunnerClient.post("#{base}/jobs",
                             { name: job.name, source_kind: source_kind_for(path),
                               input_path: path, spec: spec })
    runner_job_id = resp[:id].to_s
    raise RunnerClient::RunnerError, "the runner accepted the job with no id" if runner_job_id.blank?

    # The LIVE step's runner job is what the operator's Cancel and the file
    # proxy have to reach, so the record follows it, and the ledger's entry
    # names the label so Job#base_url resolves to THAT runner.
    entry = current_entry(job, number).merge("runner_job_id" => runner_job_id)
    write_progress!(job, current: number, total: job.steps.size, entry: entry)
    job.update_columns(runner_job_id: runner_job_id)

    final = poll_pipeline_step(job, base, runner_job_id, number, label)
    return nil if final.nil?

    state = final[:state].to_s
    if state != "done"
      raise RunnerClient::RunnerError,
            "the runner job ended #{state}#{": #{final[:error]}" if final[:error].present?}"
    end

    fact = { "path" => nil, "file" => nil, "ext" => ".svg",
             "content_type" => "image/svg+xml", "runner_job_id" => runner_job_id }
    candidate = top_candidate_file(final)
    if candidate
      fetched = RunnerClient.get_file("#{base}/files/#{runner_job_id}/#{candidate}")
      unless fetched[:status].to_i == 200
        raise RunnerClient::RunnerError,
              "the runner would not serve its top candidate #{candidate} (runner #{fetched[:status]})"
      end
      stored = store_step_file(fetched[:body], ".svg")
      fact = step_fact(stored, "image/svg+xml").merge("runner_job_id" => runner_job_id, "candidate" => candidate)
    end
    fact
  end

  # The first candidate in the runner's own ranking — the comparison arrives
  # ranked, so the first entry is the one the runner would put first.
  def top_candidate_file(data)
    comparison = data[:comparison]
    list = comparison.is_a?(Hash) ? Array(comparison["candidates"]) : []
    entry = list.find { |c| c.is_a?(Hash) && c["file"].to_s.present? }
    entry && entry["file"].to_s
  end

  # Wait for ONE pipeline step's runner job. Polling is the studio's job
  # precisely because the runner is stateless: it answers where that job got to
  # and knows nothing about the chain that posted it. Returns the runner's final
  # answer, or nil when the record stopped being "running" (cancelled).
  def poll_pipeline_step(job, base, runner_job_id, _number, _label)
    deadline = Time.current + STEP_POLL_TIMEOUT
    loop do
      return nil if cancelled?(job)

      data = RunnerClient.get("#{base}/jobs/#{runner_job_id}")
      state = data[:state].to_s
      return data if TERMINAL_RUNNER_STATES.include?(state)

      if Time.current >= deadline
        raise RunnerClient::RunnerError,
              "the runner job was still #{state} after #{STEP_POLL_TIMEOUT}s"
      end
      sleep STEP_POLL_INTERVAL
    end
  end

  # --- the chain's own end states ------------------------------------------

  def complete_chain!(job, total)
    # A chain that included a pipeline step has candidates and a comparison on
    # the runner, and they are mirrored ONCE, here, at the end — never mid-chain:
    # sync_from_runner! takes its state from the runner, and the runner's "done"
    # for step 2 of 3 is not this job's done. The chain's own verdict is written
    # last so it is the one that stands.
    notes = []
    begin
      job.sync_from_runner! if job.runner_job_id.present? && job.reload.state == "running"
    rescue StandardError => e
      # The chain's own work is DONE; a mirror that will not save is reported
      # rather than turned into a failure of what already happened.
      notes << "candidate mirror failed: #{e.message}"
    end

    job.update_columns(
      state: "done", finished_at: Time.current,
      prep_summary: (["#{total} step#{'s' if total > 1} — done"] + notes).join(" "),
      steps_state: job.reload.steps_progress.merge("state" => "done", "current" => total)
    )
  end

  # A step failed: the job fails NAMING THE STEP, and the ledger says which one
  # it was, so a half-run chain never reads as a finished one.
  def fail_step!(job, number, total, step, kind, message)
    entry = current_entry(job, number).merge("state" => "failed", "error" => message.to_s,
                                             "finished_at" => Time.current.iso8601)
    write_progress!(job, current: number, total: total, state: "failed", entry: entry)
    fail_job(job, "step #{number} (#{step['runner']}): #{message}")
  end

  # --- the ledger ----------------------------------------------------------

  # The one writer for the progress column, so its shape cannot drift: which
  # step is running (1-based), how many there are, the chain's own state, and an
  # entry per step as it is reached.
  def write_progress!(job, current:, total:, state: nil, entry: nil)
    progress = job.reload.steps_progress.deep_dup
    progress["total"] = total
    progress["current"] = current
    progress["state"] = state if state

    list = progress["steps"]
    list = [] unless list.is_a?(Array)
    if entry
      list = list.reject { |e| e.is_a?(Hash) && e["index"] == entry["index"] }
      list = (list + [entry]).sort_by { |e| e.is_a?(Hash) ? e["index"].to_i : 0 }
    end
    progress["steps"] = list

    job.update_columns(steps_state: progress)
    progress
  end

  def start_step!(job, number, total, step, kind)
    write_progress!(job, current: number, total: total, state: "running",
                    entry: { "index" => number, "runner" => step["runner"], "kind" => kind,
                             "state" => "running", "started_at" => Time.current.iso8601 })
  end

  def finish_step!(job, number, total, step, kind, fact)
    entry = current_entry(job, number).merge(
      "index" => number, "runner" => step["runner"], "kind" => kind, "state" => "done",
      "file" => fact["file"], "content_type" => fact["content_type"],
      "runner_job_id" => fact["runner_job_id"], "candidate" => fact["candidate"],
      "finished_at" => Time.current.iso8601
    )
    write_progress!(job, current: number, total: total, entry: entry)
  end

  # The entry a step already has, so a finished step keeps the started_at it was
  # recorded with.
  def current_entry(job, number)
    entry = job.reload.steps_recorded.find { |e| e.is_a?(Hash) && e["index"] == number }
    entry.is_a?(Hash) ? entry : {}
  end

  # --- what a step produced ------------------------------------------------

  # One fact hash per step, in memory for the length of the chain: the local
  # file a later step is handed, what it is, and (for a pipeline step) the
  # runner job that served it.
  def step_fact(path, content_type = nil)
    path = path.to_s
    { "path" => path, "file" => File.basename(path), "ext" => File.extname(path).downcase,
      "content_type" => content_type, "runner_job_id" => nil }
  end

  # A step's output is recorded BESIDE its request, under `rendered`, exactly
  # where a single-action job records its own — one record carries the ask and
  # the answer, per step.
  def write_step_render!(job, number, kind, facts)
    write_step_note!(job, number, kind, "rendered" => facts)
  end

  # The same write for facts that are not the output itself: what a handed file
  # was converted into, and which of its attributes the conversion had to drop.
  def write_step_note!(job, number, kind, note)
    spec = job.reload.spec
    steps = spec.is_a?(Hash) ? spec["steps"] : nil
    return unless steps.is_a?(Array) && steps[number - 1].is_a?(Hash)

    block = steps[number - 1][kind]
    block = {} unless block.is_a?(Hash)
    steps[number - 1][kind] = block.merge(note)
    job.update_columns(spec: spec)
  end

  def cancelled?(job)
    job.reload.state != "running"
  end

  # A hand-off into a pipeline runner: the runner contract takes `input_path`
  # (a file under the shared upload root) and a `source_kind` saying how to read
  # it, so the extension is what decides. storage/uploads is that root, which is
  # why a produced file can be handed over as a path rather than copied.
  def source_kind_for(path)
    File.extname(path.to_s).downcase == ".svg" ? "svg" : "raster"
  end

  def store_step_file(bytes, extension)
    uploads = Rails.root.join("storage", "uploads")
    uploads.mkpath
    dest = uploads.join("step_#{SecureRandom.hex(6)}#{extension}")
    File.binwrite(dest, bytes)
    dest
  end

  # --- the SVG -> blend hand-off --------------------------------------------
  #
  # The blend (blender) operation renders GEOMETRY: its spec is an `elements`
  # list in the vocabulary `generate` draws with, and the service REFUSES any
  # field it does not know — there is no file input on it. So a file handed to a
  # blend step is CONVERTED here, studio-side, which is the same "the studio
  # drives the chain" rule every other hand-off follows.
  #
  # The conversion is deliberately narrow and honest about its edges:
  #
  #   * only the drawing primitives the blend vocabulary has are converted, and
  #     only the attributes THAT primitive allows — anything else (a transform, a
  #     <g>, text, an image, a clip, a mask, a style attribute, a colour-space
  #     attribute) is REFUSED with the offending node or attribute named, because
  #     a silently mis-placed solid is worse than a stopped chain;
  #   * `fill-rule` and the opacity attributes have no field in the blend
  #     vocabulary, so they are DROPPED and the drop is recorded on the step
  #     (`dropped_attributes`) and in docs/step-lists.md, rather than being
  #     invented into a field the service would reject.
  BLEND_ELEMENT_FIELDS = {
    "rect"     => %w[x y width height rx fill stroke stroke_width],
    "circle"   => %w[cx cy r fill stroke stroke_width],
    "ellipse"  => %w[cx cy rx ry fill stroke stroke_width],
    "polygon"  => %w[points fill stroke stroke_width],
    "polyline" => %w[points stroke stroke_width],
    "line"     => %w[x1 y1 x2 y2 stroke stroke_width],
    "path"     => %w[d fill stroke stroke_width]
  }.freeze

  # Attributes of a converted primitive that the blend vocabulary has no field
  # for. Dropped, and recorded: they change the look, never the geometry.
  BLEND_DROPPED_ATTRIBUTES = %w[fill-rule fill-opacity stroke-opacity opacity
                                stroke-linecap stroke-linejoin stroke-dasharray].freeze

  # Nodes whose contents the conversion will not guess at. A <g> may carry a
  # transform that is exactly what makes the drawing mean what it means.
  BLEND_REFUSED_TAGS = %w[g text tspan textPath image use defs clipPath mask filter
                          marker foreignObject style switch symbol pattern linearGradient
                          radialGradient].freeze

  # Returns [elements, dropped_attributes] or raises with the reason.
  def blend_elements_from_svg(bytes)
    document = Nokogiri::XML(bytes.to_s) { |config| config.strict.nonet }
    root = document.at_css("svg")
    raise RunnerClient::RunnerError, "the handed file is not an SVG" unless root

    refused = document.css(BLEND_REFUSED_TAGS.join(",")).first
    if refused
      raise RunnerClient::RunnerError,
            "a <#{refused.name}> element cannot be expressed as blend geometry"
    end

    transformed = document.css("[transform]").first
    if transformed
      raise RunnerClient::RunnerError,
            "a <#{transformed.name}> element carries a transform, which the blend document has no way to express"
    end

    dropped = []
    elements = BLEND_ELEMENT_FIELDS.keys.flat_map do |type|
      document.css(type).map { |node| blend_element(node, type, dropped) }
    end

    if elements.empty?
      raise RunnerClient::RunnerError, "the handed SVG has no drawing primitives to render"
    end
    [elements, dropped.uniq]
  rescue Nokogiri::XML::SyntaxError => e
    raise RunnerClient::RunnerError, "the handed SVG did not parse (#{e.message})"
  end

  def blend_element(node, type, dropped)
    element = { "type" => type }
    allowed = BLEND_ELEMENT_FIELDS.fetch(type)

    node.attribute_nodes.each do |attribute|
      name = attribute.name
      next if BLEND_DROPPED_ATTRIBUTES.include?(name)

      key = name == "stroke-width" ? "stroke_width" : name
      unless allowed.include?(key)
        raise RunnerClient::RunnerError,
              "a <#{type}> element carries #{name.inspect}, which the blend vocabulary has no field for"
      end
      element[key] =
        case key
        when "points" then blend_points(attribute.value)
        when "d", "fill", "stroke" then attribute.value.to_s
        else blend_number(type, key, attribute.value)
        end
    end

    missing = (BLEND_ELEMENT_FIELDS.fetch(type) - element.keys) & blend_required_fields(type)
    unless missing.empty?
      raise RunnerClient::RunnerError, "a <#{type}> element is missing #{missing.first.inspect}"
    end

    BLEND_DROPPED_ATTRIBUTES.each { |name| dropped << name if node[name].present? }
    element
  end

  # What each primitive cannot be drawn without, which is the blend contract's
  # own list (chopshop-bp's spec.py). Checked here so a hand-written SVG is
  # refused studio-side, with the node named, rather than as a 400 after a
  # round trip to the renderer.
  def blend_required_fields(type)
    case type
    when "rect"                then %w[x y width height]
    when "circle"              then %w[cx cy r]
    when "ellipse"             then %w[cx cy rx ry]
    when "polygon", "polyline" then %w[points]
    when "line"                then %w[x1 y1 x2 y2]
    when "path"                then %w[d]
    else                            []
    end
  end

  # Coordinates are numbers in the contract; colours and path data are strings.
  # An SVG value that is not a number where one is required ("50%", "10px") is
  # refused rather than coerced.
  def blend_number(type, key, value)
    text = value.to_s.strip
    unless text.match?(/\A-?\d+(\.\d+)?([eE][-+]?\d+)?\z/)
      raise RunnerClient::RunnerError,
            "a <#{type}> element has #{key}=\"#{text}\", which is not a number"
    end
    text.include?(".") || text.match?(/[eE]/) ? text.to_f : text.to_i
  end

  # SVG packs a polyline's points into one string; the contract wants [x, y]
  # pairs.
  def blend_points(value)
    numbers = value.to_s.split(/[\s,]+/).reject(&:empty?)
    if numbers.size.odd? || numbers.empty?
      raise RunnerClient::RunnerError, "a points attribute with #{numbers.size} numbers is not coordinate pairs"
    end
    numbers.map { |n| blend_number("points", "points", n) }.each_slice(2).to_a
  end

  # The studio-side progress line, for the job page's poll card. Each kind says
  # what it is actually doing: a generator draws a raster for the pipeline, a
  # plot service draws the deliverable, a blender runner renders it, a pipeline
  # runner is dispatched to.
  def activity_line(job)
    if job.sequenced?
      steps = job.steps
      return "step 1 of #{steps.size}: #{steps.first['runner']}…"
    end
    return "generating raster…" if job.flux?
    return "drawing plot…" if job.plot?
    return "rendering…" if job.blender?
    "dispatching to #{job.runner}…"
  end

  # The generation settings, read from whichever job carries them: a real job
  # for a single-action flux run, an unsaved per-step probe for a step of a
  # chain. ONE list, so the two paths cannot ask the service for different
  # things, and so a setting added to the flux block is added in one place.
  #
  # `reference` is the hand-off: the file the step before this one produced,
  # already resolved to a stored upload. Nil means "read the block's own image",
  # which is what a single-action img2img job does.
  def flux_render_options(job, reference: nil)
    {
      prompt: job.flux_prompt,
      reference: reference || flux_reference_data_url(job),
      model: flux_setting(job, "model"),
      width: flux_setting(job, "width"),
      height: flux_setting(job, "height"),
      steps: flux_setting(job, "steps"),
      guidance: flux_setting(job, "guidance"),
      seed: flux_setting(job, "seed"),
      images: flux_setting(job, "images"),
      negative_prompt: flux_setting(job, "negative_prompt"),
      # img2img-only, and only for a model that takes one: the service ignores
      # it otherwise. flux_setting blanks out to nil, so an empty field means
      # the service's own default rather than a zero strength.
      strength: flux_setting(job, "strength"),
      # The LoRA stack and the decoder swap, from the same spec.flux block, so
      # the job page can show what was asked for beside what came back.
      modifiers: flux_setting(job, "modifiers"),
      modifier_scales: flux_setting(job, "modifier_scales"),
      vae: flux_setting(job, "vae")
    }
  end

  # A flux job's generation happens HERE, in-process, so the worker holds the
  # serial slot for the whole generation (tens of seconds) — which is exactly
  # what "one flux job at a time" means. Only after the raster lands is the job
  # either done (raster-only) or handed to a pipeline runner for tracing.
  def run_flux(job)
    rendered = FluxClient.render(job.generator_base_url, **flux_render_options(job))

    # Cancelled while the box was drawing: drop the raster and never hand it off.
    return if job.reload.state != "running"

    rasters = store_flux_rasters(job, rendered)
    facts = flux_render_facts(job, rendered, rasters)
    spec = job.spec.merge("flux" => job.flux_config.merge("rendered" => facts))

    if job.raster_only?
      # Nothing to trace: the picture IS the deliverable. Every variation is
      # kept; the first is the job's primary raster, the rest are previewed on
      # the job page and saveable.
      #
      # There is also no RUNNER here, so there is no prep stage and no
      # source.inverse.png for the job page's source/inverse pair to proxy. The
      # twin is inverted from the raster itself, now, and recorded with the rest
      # of the render facts — one name the page, the popup and the download
      # bundle all read. A raster the inverter cannot read (an unusual PNG)
      # leaves the job complete with no twin; its tile self-hides.
      inverse = FluxInverseTwin.write(File.basename(rasters.first.to_s))
      spec = spec.merge("flux" => spec["flux"].merge("rendered" => facts.merge("inverse" => inverse))) if inverse

      job.update!(spec: spec, input_path: rasters.first.to_s, state: "done",
                  candidate_count: 0, finished_at: Time.current,
                  prep_summary: "flux raster — #{rendered[:name]}")
    else
      # TRACE MODE, and a batch: spec.flux.images > 1 asked the service for
      # several variations and every one of them is stored as an upload — but
      # only the FIRST is handed to the pipeline. `input_path` is rasters.first
      # and exactly ONE pipeline job is created, so one variation is traced and
      # the rest are previewed on the job page (spec[...]["rendered"]["images"])
      # and saveable, never traced.
      #
      # Per-variation tracing is NOT built, deliberately: it would mean one
      # pipeline job per raster and a job record with several traced trees, which
      # is a feature decision rather than a fix. This comment is here so the
      # behaviour is documented instead of being discovered.
      handoff = Job.handoff_runner
      raise RunnerClient::RunnerError,
            "no pipeline runner is configured to hand the raster to" unless handoff
      job.update!(spec: spec.merge("flux" => spec["flux"].merge("handoff" => handoff)),
                  input_path: rasters.first.to_s, prep_summary: "handed to #{handoff}")
      resp = RunnerClient.create_job(job)
      job.update!(runner_job_id: resp[:id], state: "running")
    end
  end

  # A plot job's drawing happens HERE, in-process and synchronously: the service
  # takes one document and answers with one SVG -- no queue, no GPU, no job to
  # poll -- so the worker holds the serial slot only for the round trip. Nothing
  # sleeps or polls, because there is nothing to wait for.
  #
  # The result is stored like any other upload (a file in storage/uploads) and
  # the job is DONE when it lands: a plot draws a report, it does not trace, so
  # there are no candidates to gate and no runner to hand anything to.
  def run_plot(job)
    op = job.plot_op
    rendered =
      case op
      when "query"  then PlotClient.query(job.base_url, job.plot_runs, job.plot_doc)
      when "digest" then PlotClient.digest(job.base_url, job.plot_doc)
      else               PlotClient.generate(job.base_url, job.plot_doc)
      end

    # Cancelled while the service was drawing: drop the SVG and store nothing.
    return if job.reload.state != "running"

    stored = store_plot_svg(rendered)
    name = File.basename(stored.to_s)

    job.update!(
      spec: job.spec.merge(
        "plot" => job.plot_config.merge(
          "rendered" => { "file" => name, "op" => rendered[:op],
                          "content_type" => rendered[:content_type] }
        )
      ),
      state: "done", candidate_count: 0, finished_at: Time.current,
      prep_summary: "plot #{op} — #{name}"
    )
  end

  # A BP job is ONE action over the whole blend-plot service, so this is the two
  # paths below (run_plot, run_blender) reached through one door: the operation
  # decides which half answered, and the answer is stored and recorded exactly as
  # that half's own job would have stored and recorded it.
  #
  # It happens HERE, in-process and synchronously, for the same reason both of
  # those do: the service takes one document and answers with one document or one
  # render — no queue, no GPU, no job to poll — so the worker holds the serial
  # slot only for the round trip and nothing sleeps.
  #
  # The result is stored like any other upload (a file in storage/uploads) and
  # the job is DONE when it lands: bp draws or renders a deliverable, it does not
  # trace, so there are no candidates to gate and no runner to hand anything to.
  def run_bp(job)
    op = job.bp_op
    base = job.base_url

    if op == "blender"
      rendered = BpClient.render(base, op, job.bp_doc)
      # Cancelled while the service was rendering: drop the frames, store nothing.
      return if job.reload.state != "running"

      stored = store_blender_frames(rendered)
      name = File.basename(stored.first.to_s)
      facts = blender_render_facts(job, rendered, stored, name, doc: job.bp_doc)
      write_bp_result(job, facts, "bp blender — #{name}")
    else
      rendered = BpClient.render(base, op, job.bp_doc,
                                 runs: (op == "query" ? job.bp_runs : nil))
      # Cancelled while the service was drawing: drop the SVG and store nothing.
      return if job.reload.state != "running"

      stored = store_plot_svg(rendered)
      name = File.basename(stored.to_s)
      write_bp_result(job, { "file" => name, "op" => rendered[:op],
                             "content_type" => rendered[:content_type] },
                      "bp #{op} — #{name}")
    end
  rescue PlotClient::PlotError, BlenderClient::BlenderError => e
    # One name for a BP job's failure (see BpClient::Error): the underlying half
    # is still named in the message, which is the part that tells the operator
    # what to look at.
    raise BpClient::Error, e.message
  end

  # The ask and the answer in one record, under the same block — so the job page
  # reads one place regardless of which of the six operations ran.
  def write_bp_result(job, rendered_facts, summary)
    job.update!(
      spec: job.spec.merge("bp" => job.bp_config.merge("rendered" => rendered_facts)),
      state: "done", candidate_count: 0, finished_at: Time.current,
      prep_summary: summary
    )
  end

  # One step of a chain, when the step names a BP runner. Same two halves as
  # run_bp, plus the hand-off: a bp step asked for `blender` and handed a file
  # converts that SVG studio-side into the blend document's own element
  # vocabulary, because the blender operation renders GEOMETRY and has no file
  # input to hand a path to (the same rule run_blender_step follows).
  def run_bp_step(job, step, number, input)
    probe = step_probe(job, step)
    op = probe.bp_op
    base = Job.runners.fetch(step["runner"])

    if op == "blender"
      doc = (probe.bp_doc || {}).deep_dup
      if input
        derived, dropped = blend_elements_from_svg(File.binread(input))
        doc["elements"] = Array(doc["elements"]) + derived
        write_step_note!(job, number, "bp",
                         { "document_from" => File.basename(input.to_s),
                           "elements_from_svg" => derived.size,
                           "dropped_attributes" => dropped })
      end

      rendered = BpClient.render(base, op, doc)
      return nil if cancelled?(job)

      stored = store_blender_frames(rendered)
      name = File.basename(stored.first.to_s)
      facts = blender_render_facts(probe, rendered, stored, name, doc: doc)
      write_step_render!(job, number, "bp", facts)
      step_fact(stored.first, "image/png")
    else
      rendered = BpClient.render(base, op, probe.bp_doc,
                                 runs: (op == "query" ? probe.bp_runs : nil))
      return nil if cancelled?(job)

      stored = store_plot_svg(rendered)
      name = File.basename(stored.to_s)
      write_step_render!(job, number, "bp",
                         { "file" => name, "op" => rendered[:op],
                           "content_type" => rendered[:content_type] })
      step_fact(stored, "image/svg+xml")
    end
  rescue PlotClient::PlotError, BlenderClient::BlenderError => e
    raise BpClient::Error, e.message
  end

  def store_plot_svg(rendered)
    uploads = Rails.root.join("storage", "uploads")
    uploads.mkpath
    dest = uploads.join("plot_#{SecureRandom.hex(6)}.svg")
    File.binwrite(dest, rendered[:bytes])
    dest
  end

  # A blender job's render happens HERE, in-process and synchronously, for the
  # same reason a plot job's drawing does: the service takes one document and
  # answers with one frame (or a manifest of them) — no queue and no job to poll
  # — so the worker holds the serial slot for the round trip. Blender is slower
  # than a 2D draw, which is what the client's longer read timeout is for.
  #
  # The frames are stored like any other upload and the job is DONE when they
  # land: a render IS the deliverable, so there are no candidates to gate and no
  # runner to hand anything to.
  def run_blender(job)
    label = blender_runner_for(job)
    raise BlenderClient::Unavailable,
          "no blender runner is configured to render on" unless label

    rendered = BlenderClient.render(Job.runners.fetch(label), job.blender_doc)

    # Cancelled while the service was rendering: drop the frames and store
    # nothing.
    return if job.reload.state != "running"

    stored = store_blender_frames(rendered)
    name = File.basename(stored.first.to_s)

    # The render facts ride under the job's own blender block, beside the
    # document that asked for them, so one record carries both the ask and the
    # answer — the same arrangement a plot job uses.
    job.update!(
      spec: job.spec.merge(
        "blender" => job.blender_config.merge(
          "rendered" => blender_render_facts(job, rendered, stored, name)
        )
      ),
      state: "done", candidate_count: 0, finished_at: Time.current,
      prep_summary: "blender render — #{name}"
    )
  end

  # Which runner renders this job: the blender runner it was filed against when
  # that label IS one (the normal case — Job#blender? asked the same registry),
  # else the first configured blender runner. Nil when the deployment has none,
  # which is the one case RunJob has to report rather than attempt.
  def blender_runner_for(job)
    return job.runner if Job.blender_runner?(job.runner)
    Job.blender_runners.first
  end

  # Every frame the answer carried, written as a normal storage/uploads PNG. A
  # single-view render (views == 1) answers with its frame in the response body;
  # a multi-view one answers with a manifest, and the client has already fetched
  # each of those frames — so this is the same write either way, and a set is
  # never silently reduced to its first element.
  def store_blender_frames(rendered)
    entries = Array(rendered[:entries]).presence || [rendered]
    uploads = Rails.root.join("storage", "uploads")
    uploads.mkpath
    entries.map do |entry|
      dest = uploads.join("blender_#{SecureRandom.hex(6)}.png")
      File.binwrite(dest, entry[:bytes])
      dest
    end
  end

  # The facts worth keeping about a render: the frame that landed and the whole
  # set when the manifest named one, plus the render settings the answer was
  # produced with — size, views and engine — and the exported GLB's name.
  #
  # `views` comes from the ANSWER rather than from the document's render block:
  # the manifest is what actually came back, so it is what is recorded, and a
  # service that answered with more or fewer frames than asked for is visible in
  # the record rather than hidden by it.
  def blender_render_facts(job, rendered, stored, name, doc: nil)
    doc = doc || job.blender_doc || {}
    render = doc["render"].is_a?(Hash) ? doc["render"] : {}
    size = render["size"].is_a?(Hash) ? render["size"] : BlenderConf::DEFAULT_SIZE
    {
      "file" => name,
      "files" => stored.map { |path| File.basename(path.to_s) },
      "service_name" => rendered[:name],
      "frames" => rendered[:frames],
      "size" => size,
      "views" => rendered[:views],
      "engine" => render["engine"].to_s.strip.presence || BlenderConf::DEFAULT_ENGINE,
      "glb" => rendered[:glb],
      "content_type" => rendered[:content_type]
    }
  end

  def run_pipeline(job)
    resp = RunnerClient.create_job(job)
    job.update!(runner_job_id: resp[:id], state: "running")
  end

  # Record the failure on the studio record, so the operator sees the reason.
  #
  # `update_columns` rather than `update!` for one reason: the model validates
  # that a job's runner is one of the CONFIGURED runners, so a job whose runner
  # has since been removed from the deployment fails that validation on every
  # save — and a failure that cannot be written down is a failure nobody can see.
  # This is the one write that has to land regardless; the DB's own constraints
  # still apply, only the model's validations are bypassed.
  def fail_job(job, message)
    return unless job
    job.update_columns(state: "error", error: message, finished_at: Time.current)
  end

  # The spec's flux block as the service wants it: blank values are omitted
  # rather than sent as empty strings, so the service's own defaults apply and a
  # blank field cannot mean something different from an absent one.
  #
  # A LIST or a MAP is returned whole rather than stringified: `modifiers` is an
  # array and `modifier_scales` an object in the spec, and `Array#to_s` would
  # hand the service the literal text of the array. An empty one is nil, on the
  # same rule as a blank string — nothing was asked for, so nothing is sent.
  def flux_setting(job, key)
    value = job.flux_config[key]
    return value.presence if value.is_a?(Array) || value.is_a?(Hash)
    value.to_s.strip.presence
  end

  # An uploaded reference for /edit, as the data URL the service requires. Nil
  # for a plain generation. Re-validated here (not just in the controller)
  # because the spec is user-editable text and generation is where the path is
  # actually consumed.
  def flux_reference_data_url(job)
    name = job.flux_config["image"].to_s.strip
    return nil if name.blank?
    self.class.validate_reference!(name)
    FluxClient.data_url(Rails.root.join("storage", "uploads", File.basename(name)).to_s)
  end

  def store_flux_rasters(job, rendered)
    entries = Array(rendered[:entries]).presence || [rendered]
    uploads = Rails.root.join("storage", "uploads")
    uploads.mkpath
    entries.map do |e|
      dest = uploads.join("flux_#{SecureRandom.hex(6)}.png")
      File.binwrite(dest, e[:bytes])
      dest
    end
  end

  # The facts worth keeping about the generation: a summary of the first image
  # (the job's primary raster) plus the full list of variations, so a batch is
  # previewable and a raster is reproducible from its seed.
  #
  # The LoRA stack and the decoder swap are recorded here too, beside the seed
  # and the size: they change what the pixels ARE as much as the prompt does, and
  # a raster whose modifiers were not written down is not reproducible from the
  # record even with the same seed. What is recorded is what was ASKED for (the
  # service's own echo wins when it sends one), which is the same arrangement
  # `model` uses under `files`, and like every other fact here a blank is dropped
  # rather than stored as an empty list.
  def flux_render_facts(job, rendered, stored_paths)
    entries = Array(rendered[:entries]).presence || [rendered]
    images = entries.each_with_index.map do |e, i|
      entry = e[:entry] || {}
      {
        "file" => stored_paths[i] && File.basename(stored_paths[i].to_s),
        "name" => e[:name],
        "seed" => entry["seed"],
        "model" => entry["model"],
        "width" => entry["width"],
        "height" => entry["height"],
        "seconds" => entry["seconds"]
      }.compact
    end
    entry = rendered[:entry] || {}
    meta = rendered[:meta] || {}
    {
      "name" => rendered[:name],
      "seed" => entry["seed"],
      "model" => entry["model"],
      "width" => entry["width"],
      "height" => entry["height"],
      "seconds" => entry["seconds"],
      "license" => rendered.dig(:meta, "license"),
      "commercial_ok" => rendered.dig(:meta, "commercial_ok"),
      "warnings" => Array(rendered.dig(:meta, "warnings")),
      "modifiers" => (meta["modifiers"] || flux_setting(job, "modifiers")).presence,
      "modifier_scales" => (meta["modifier_scales"] || flux_setting(job, "modifier_scales")).presence,
      "vae" => (meta["vae"] || flux_setting(job, "vae")).presence,
      "images" => images
    }.compact
  end
end
