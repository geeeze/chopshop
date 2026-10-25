# DATASETS — the public corpora this studio draws from, and the one page that
# makes them usable rather than decorative.
#
# Two datasets, two different kinds of useful:
#
#   * **DiffusionDB** supplies PROMPTS. Real sentences written by real people
#     driving Stable Diffusion, with the hyperparameters those people used and
#     the dataset's own 2-D projection of prompt space. A prompt is drawn from
#     the library and generated FOR REAL on the Run Job form, so the library is
#     a working prompt source and not a gallery.
#   * **MET-Meme** supplies a SCHEMA. Its annotation vocabulary (metaphor,
#     sentiment, intention, offensiveness) is what a meme artefact here is
#     labelled with, and the module that transcribes it is pinned against the
#     source's own README (see MemeVocabulary). Its images stay on Kaggle; this
#     page says so rather than implying otherwise.
#
# THE MAP is drawn by the blend-plot service from the library's own coordinates —
# `digest` with a scatter, one series per topic — so it is a real drawing of real
# data and it is a VECTOR document like every other drawing here. A service that
# is down leaves the drawing out and the page says why; it never 500s.
class DatasetsController < ApplicationController
  PAGE_SIZE = 40

  # The SELECTS' rendered window. The library's topic labels are descriptive
  # slugs — 60,000 prompts carry thousands of them — so an uncapped <select>
  # ships 9,633 topic options and 1,968 phrase-root options in the first paint
  # (~1.17 MB of markup before any interaction). The select ships the most
  # common values BY ROW COUNT (the option label embeds the count, vatican-kb
  # style); the tail is NOT duplicated in the page. It stays reachable through
  # the "search all N" affordance, which reads the full ranked vocabulary from
  # the library JSON (`/datasets/library`) rather than from markup. Reverting
  # this is restoring the full `options_for_select` over the whole hash.
  SELECT_LIMIT = 200

  # The map's shape. Per SERIES, and stated on the page: a scatter that drew a
  # different number of points per topic would read as density rather than as a
  # sample, so the sampling is printed instead of being hidden by the drawing.
  MAP_POINTS_PER_TOPIC = 300
  # How many topics get a series of their own. The library's topic labels are
  # descriptive slugs — 60,000 prompts carry thousands of them — so a legend with
  # one entry per topic is not a map; the rest fold into a stated "other topics".
  MAP_TOP_TOPICS = 10
  MAP_SIZE = { "width" => 1200, "height" => 640 }.freeze

  before_action :require_login
  before_action :load_filters, only: %i[index library surface]

  def index
    load_surface
  end

  # The cards on their own, for the FLUX page's DATASETS popup: the SAME partial
  # the page renders, with no layout and no page head, so the library has one
  # definition instead of a page and a popup that drift. The popup fetches this
  # when it opens rather than the FLUX page rendering it, because the map is
  # drawn by the blend-plot service and a page load should not wait on a drawing
  # nobody has asked to see.
  def surface
    load_surface
    render partial: "datasets/surface", layout: false
  end

  # The library as JSON: the census, the filters in force, and the rows of this
  # page in the CONTRACT shape (PromptSource#to_contract). This is the twin an
  # agent reads to pick a prompt without scraping the table.
  #
  # It ALSO carries the FULL ranked vocabulary (`topics`, `roots`) — every value
  # with its row count, not just the top-N the page's selects render. The page's
  # "search all N" affordance reads these lists, so the tail the selects leave
  # out is reachable from the API rather than duplicated in markup.
  def library
    scope = filtered
    limit = (params[:limit].presence || 20).to_i.clamp(1, 200)
    rows = scope.order(:id).limit(limit)
    render json: { "census" => PromptSource.census,
                   "topics" => ranked_counts(:topic).map { |k, n| { "name" => k, "count" => n } },
                   "roots" => ranked_counts(:phrase_root).map { |k, n| { "name" => k, "count" => n } },
                   "filters" => { "topic" => params[:topic], "phrase_root" => params[:root],
                                  "q" => params[:q] },
                   "count" => scope.count,
                   "prompt" => rows.map(&:to_contract) }
  end

  # ONE prompt, drawn at random, optionally filtered: what a caller wants when it
  # needs a prompt rather than a list of them. `?topic=…&root=…&count=N`, or
  # `?view=NAME` to draw from a curated view (issue #48) — a named filter whose
  # rule and manifest live in the DatasetView, so a draw from a view is the same
  # honest, deterministic slice the view defined.
  def draw
    count = (params[:count].presence || 1).to_i.clamp(1, 20)
    prompts =
      if params[:view].present?
        view = DatasetView.find_by(name: params[:view])
        return render json: { "error" => "no view named #{params[:view]}" }, status: :not_found unless view

        view.draw(count)
      else
        Array.new(count) do
          PromptSource.draw(topic: params[:topic].presence, phrase_root: params[:root].presence)
        end.compact
      end

    render json: { "count" => prompts.size,
                   "prompts" => prompts.map(&:to_contract) }
  end

  # Put one prompt on the Run Job form. The studio's own hand-off shape: the
  # prompt is stored as a DRAFT and the form reads it as a DEFAULT the operator
  # then edits — never as a committed value, and never silently replacing what
  # they had already typed. A draft rather than the session because prompts are
  # unbounded text and the session is a 4 KB cookie (see SessionDraft).
  def use
    prompt = PromptSource.find_by(id: params[:id]) if params[:id].present?
    prompt ||= PromptSource.draw
    return redirect_to datasets_path, alert: "the library is empty — ingest it first" if prompt.nil?

    token = SessionDraft.store(kind: SessionDraft::PROMPT, body: prompt.prompt,
                               source: prompt.provenance)
    redirect_to new_job_path(prompt_draft_token: token),
                notice: "prompt drawn from the #{prompt.dataset} library"
  end

  # The MET-Meme scheme, as JSON. A page renders it and an agent reads it from
  # here; both come from MemeVocabulary, so there is one transcription.
  def meme_labels
    render json: MemeVocabulary.to_contract
  end

  # The BATCH DRIVER (issue #46): file N generation jobs, one per drawn prompt,
  # with a manifest. The volume path over the single-draw — a human picks
  # which of the filed jobs to run.
  #
  # Params: count, topic, root, view, project_id. The same filter vocabulary
  # #draw takes, plus the project the jobs are filed under. Returns the
  # manifest JSON so the UI can show what was filed without a second query.
  #
  # The jobs are filed as PENDING — the pipeline convention is that this layer
  # produces sources + a manifest; a human picks. The operator runs them from
  # the job page.
  def batch
    count = (params[:count].presence || 20).to_i.clamp(1, 200)
    project_id = params[:project_id].presence
    return render json: { "error" => "project_id is required — a job with no project is listed nowhere under the workspace" },
                  status: :unprocessable_entity unless project_id

    result = DatasetBatch.run(
      count: count,
      topic: params[:topic].presence,
      root: params[:root].presence,
      view: params[:view].presence,
      seed: params[:seed].presence || DatasetBatch::DEFAULT_SEED,
      project_id: project_id
    )

    unless result.ok?
      status = result.error.include?("no view named") ? :not_found : :unprocessable_entity
      return render json: { "error" => result.error }, status: status
    end

    manifest = JSON.parse(result.path.read)
    render json: manifest
  end

  private

  # Everything the surface needs, loaded in ONE place so the page (index) and the
  # popup (surface) cannot read a different library. `@page` is shared too: the
  # popup's own pagination links are the page's, so page 2 in a popup and page 2
  # of the page are the same rows.
  def load_surface
    @census = PromptSource.census
    @topics = ranked_counts(:topic)
    @roots = ranked_counts(:phrase_root)

    # The selects render only the top-N of each ranked list (SELECT_LIMIT); the
    # totals are kept so the affordance can say how much is behind it.
    @topics_total = @topics.size
    @roots_total = @roots.size
    @topics_options = @topics.first(SELECT_LIMIT)
    @roots_options = @roots.first(SELECT_LIMIT)
    # A filter in force must stay VISIBLE in its own select: a bookmarked value
    # outside the top-N used to be selectable (the select shipped everything);
    # now it would silently show "any" while the results below are filtered by
    # it. Inject the in-force value as an explicit option when the cap cut it,
    # so the select always tells the truth about what is applied (issue #12).
    if (topic = @filters["topic"]).presence && @topics_options.none? { |k, _| k == topic }
      @topics_options << [topic, ranked_counts(:topic)[topic] || 0]
    end
    if (root = @filters["phrase_root"]).presence && @roots_options.none? { |k, _| k == root }
      @roots_options << [root, ranked_counts(:phrase_root)[root] || 0]
    end

    @page = (params[:page].presence || 1).to_i.clamp(1, 10_000)
    @rows = filtered.order(:id).offset((@page - 1) * PAGE_SIZE).limit(PAGE_SIZE)
    @matches = filtered.count
    @pages = [ (@matches / PAGE_SIZE.to_f).ceil, 1 ].max

    @drawn_prompt = PromptSource.draw(topic: @filters["topic"],
                                      phrase_root: @filters["phrase_root"]) || PromptSource.draw

    # The map is drawn ON DEMAND: the 186 KB inline SVG of 3,295 circles is
    # ~1.17 MB of the first paint, so the page ships a "draw the map" control
    # instead and only asks the blend-plot service when the operator asks for
    # it (`?map=1`). The popup fetches this surface the same way, so it too
    # defers the drawing to the click.
    @map_svg = library_map_svg if params[:map].present?
    @labels = MemeVocabulary.to_contract
  end

  # The filters, read ONCE for every action that reads the library. `library`
  # calls `filtered` too, and a filter set inside `index` alone left the JSON
  # action dereferencing nil — one reader, both callers.
  def load_filters
    @filters = { "topic" => params[:topic].presence,
                 "phrase_root" => params[:root].presence,
                 "q" => params[:q].presence }
  end

  # A filter list's counts, ranked. The order is stated in SQL rather than in
  # Ruby because the counts are grouped by the database, and the tie-break is the
  # column itself so two equally common topics do not swap places between
  # renders.
  def ranked_counts(column)
    PromptSource.where.not(column => nil)
                .group(column)
                .order(Arel.sql("count(*) DESC, #{column} ASC"))
                .count
  end

  def filtered
    scope = PromptSource.all
    scope = scope.where(topic: @filters["topic"]) if @filters["topic"].present?
    scope = scope.where(phrase_root: @filters["phrase_root"]) if @filters["phrase_root"].present?
    if @filters["q"].present?
      # A LIKE rather than a full-text index: the library is a slice, the search
      # is for a phrase the operator half-remembers, and SQLite's LIKE over an
      # indexed prefix is fast enough at this size. The escape is explicit so a
      # prompt containing % searches for % rather than for everything.
      needle = "%#{@filters['q'].gsub(/[\\%_]/) { |c| "\\#{c}" }}%"
      scope = scope.where("prompt LIKE ? ESCAPE '\\'", needle)
    end
    scope
  end

  # The prompt-space map, drawn by the blend-plot service from the library's own
  # coordinates.
  def library_map_svg
    label = Job.plot_runners.find { |r| r != "mock" } || Job.plot_runners.first
    return nil if label.blank?

    series = PromptSource.map_series(per_topic: MAP_POINTS_PER_TOPIC, top: MAP_TOP_TOPICS)
    return nil if series.empty?

    doc = { "op" => "digest", "doc" => {
      "chart" => "scatter",
      "title" => "DiffusionDB prompt space — top #{MAP_TOP_TOPICS} topics + the rest, " \
                 "#{series.sum { |s| s['points'].size }} sampled points",
      "size" => MAP_SIZE,
      "data" => { "series" => series }
    } }

    result = BpClient.render(Job.runners.fetch(label), "digest", doc["doc"])
    svg = result[:bytes].to_s.dup.force_encoding(Encoding::UTF_8)
    svg.valid_encoding? ? svg : nil
  rescue PlotClient::PlotError, BpClient::Error => e
    @map_error = e.message
    nil
  end
end
