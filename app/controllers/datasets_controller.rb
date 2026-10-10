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
  def library
    scope = filtered
    limit = (params[:limit].presence || 20).to_i.clamp(1, 200)
    rows = scope.order(:id).limit(limit)
    render json: { "census" => PromptSource.census,
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

  private

  # Everything the surface needs, loaded in ONE place so the page (index) and the
  # popup (surface) cannot read a different library. `@page` is shared too: the
  # popup's own pagination links are the page's, so page 2 in a popup and page 2
  # of the page are the same rows.
  def load_surface
    @census = PromptSource.census
    @topics = ranked_counts(:topic)
    @roots = ranked_counts(:phrase_root)

    @page = (params[:page].presence || 1).to_i.clamp(1, 10_000)
    @rows = filtered.order(:id).offset((@page - 1) * PAGE_SIZE).limit(PAGE_SIZE)
    @matches = filtered.count
    @pages = [ (@matches / PAGE_SIZE.to_f).ceil, 1 ].max

    @drawn_prompt = PromptSource.draw(topic: @filters["topic"],
                                      phrase_root: @filters["phrase_root"]) || PromptSource.draw
    @map_svg = library_map_svg
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
