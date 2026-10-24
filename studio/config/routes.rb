Rails.application.routes.draw do
  root "projects#index"

  get    "login",  to: "application#login"
  post   "login",  to: "application#authenticate"
  delete "logout", to: "application#logout"

  # spec builder + info pages
  get  "json",     to: "pages#schema",     as: :json
  post "json/use", to: "pages#apply_spec", as: :use_json
  # Apply a TEMPLATE to the contract on the new-run form. The twin of
  # `json/use`: both take a document and hand it to the Run Job form as a draft,
  # and both are POST because they change what the operator is looking at.
  post "templates/use", to: "pages#apply_template", as: :use_template
  get  "jev",      to: "pages#jev",        as: :jev
  get  "about",    to: "pages#about",      as: :about
  # FLUX — the generation service's settings and model registry. Sits after
  # About in the nav because it is a reference page, like the two beside it.
  get  "flux",     to: "pages#flux",       as: :flux
  # BP — Blend-Plot: chopshop-bp's WHOLE serve surface on one page, because the
  # two halves are one service. `plot` draws documents (the geometry source, the
  # metrics digest, the cross-run query engine) and `blend` renders geometry in
  # 3D. A reference page like FLUX and JEV, after JEV in the nav.
  get  "bp",       to: "pages#bp",         as: :bp
  # PLOT and BLENDER were separate pages until the halves were recognised as one
  # service. Both named routes stay -- existing links and bookmarks reach them --
  # and both REDIRECT to /bp (pages#plot / pages#blender are redirects now).
  get  "plot",     to: "pages#plot",       as: :plot
  get  "blender",  to: "pages#blender",    as: :blender
  # STATUS — the telemetry surface: what this studio has PRODUCED (the pipeline-use
  # bar chart), what this HOST was doing while it did (the server line chart, from
  # HostSample's minute samples) and the recorded event log. The two charts are
  # chopshop-bp `digest` documents and the log is a `log` one. The source → job →
  # candidate HIERARCHY that used to lead the page is gone deliberately — it
  # restated the jobs table in a shape no number could be read out of — and
  # test/controllers/status_page_test.rb pins its absence structurally, including
  # that the `tree` operation is never asked for. Reached from the footer's
  # check-engine light rather than the header nav: it reports what the pages beside
  # it configure rather than being a step on the working path.
  get  "status",   to: "pages#status",     as: :status

  # AUDIT -- the studio's data debt, counted (#95). One route, two shapes:
  # `/audit` is the page, `/audit.json` is the document (the studio serves JSON
  # as a format on its own routes, so there is no `/api` namespace). The page's
  # own filters are read-only GETs on the same route -- `?gap=<group>.<key>` is
  # the id list behind ONE count, `?project=<id>` the unresolved ids in ONE
  # project. Login-gated, read-only, and cheap enough to poll: aggregate counts
  # plus id lists, never a join of whole tables.
  get    "audit",    to: "audit#show",       as: :audit

  # GRAPH -- the studio's own records as ONE shape (#96, facelift 4/4): every
  # project, job, candidate and proof the signed-in owner can see, joined by the
  # containment and pick lines between them, drawn as a force-directed SVG. One
  # route, two shapes: `/graph` is the page, `/graph.json` is the document (the
  # studio serves JSON as a format on its own routes, so there is no `/api`
  # namespace; the kb's `/api/graph` is the SHAPE this follows, not a path
  # mandate). Login-gated like every other authed route: the nodes are this
  # owner's own records, and every node's art URL is one of this app's own
  # login-gated file routes. Reached from the FOOTER, beside the audit pill --
  # the header nav is the working path (Projects · JSON · FLUX · JEV · BP) and
  # does not grow for a surface that cannot act on a job.
  get    "graph",    to: "graphs#show",      as: :graph

  # DATASETS -- the public corpora this studio draws from: DiffusionDB prompts
  # (browsable, mapped, and generated from for real) and MET-Meme's annotation
  # vocabulary. A reference page's job, but a working one: a prompt drawn here
  # goes onto the Run Job form.
  get  "datasets",            to: "datasets#index",   as: :datasets
  get  "datasets/library",    to: "datasets#library", as: :library_datasets
  get  "datasets/draw",       to: "datasets#draw",    as: :draw_datasets
  get  "datasets/meme-labels", to: "datasets#meme_labels", as: :meme_labels_datasets
  post "datasets/use",        to: "datasets#use",     as: :use_datasets
  # The batch driver (issue #46): file N jobs from the library in one action.
  # POST because it files jobs; returns the manifest JSON.
  post "datasets/batch",      to: "datasets#batch",   as: :batch_datasets

  # The iterative mashup UX (#51): synthesize N prompts into one, then let the
  # operator re-mash with temperature escalation, revert, and use the result.
  # State lives in a MashupChain (SessionDraft, kind: MASHUP), so the chain
  # survives navigation and reload for free.
  post "mashup",              to: "mashups#create",   as: :mashups
  get  "mashup/:token",       to: "mashups#show",     as: :mashup
  post "mashup/:token/remash", to: "mashups#remash",  as: :remash_mashup
  post "mashup/:token/revert", to: "mashups#revert",  as: :revert_mashup
  post "mashup/:token/use",   to: "mashups#use",     as: :use_mashup
  # The surface WITHOUT the page head or the layout: what the FLUX page's
  # DATASETS popup fetches, so the library has one definition rather than a page
  # and a popup that drift. Not a format of #index because it renders a partial
  # and no wrapper at all.
  get  "datasets/surface",    to: "datasets#surface", as: :surface_datasets

  resources :jobs, only: %i[show new create] do
    collection do
      post :upload
      get  "upload_preview/:name", to: "jobs#upload_preview", as: :upload_preview,
           format: false, constraints: { name: /[\w.\-]+/ }
    end
    member do
      get :refresh
      get :file, as: :file
      get :download
      # A proof's training set (the `.dataset.7z`), built on demand by the
      # runner. A sibling of #download because it is the same kind of read --
      # an archive the runner builds while the caller waits.
      get :dataset
      post :use_inverse
      post :reuse
      post :cancel
      delete :destroy
    end
  end

  # A back-half run is a PROOF, and "proofs" is the name the operator reads --
  # including in the address bar. The controller/model keep their internal
  # Validation names; only the URL is part of the vocabulary.
  resources :validations, path: "proofs", only: %i[show create] do
    member do
      post :ask_jev
      get  :refresh
    end
  end

  # Scrapbook — the operator's own store of favourited sources/inverts/candidates/
  # proofs, kept in storage/scrapbook so it survives the jobs it came from. Read
  # and written from the left sidebar.
  get    "scrapbook",          to: "scrapbooks#index",   as: :scrapbook
  post   "scrapbook",          to: "scrapbooks#create"
  # Save a local upload (a generated flux raster) into the scrapbook — the
  # variations on a flux job have no runner file behind them, so the favourite
  # path (which fetches through the runner) cannot reach them.
  post   "scrapbook/save_upload", to: "scrapbooks#save_upload", as: :scrapbook_save_upload
  # Import a raw PNG/JPEG (an edited scrape from the sidebar's canvas editor)
  # as a new scrapbook item.
  post   "scrapbook/import",   to: "scrapbooks#import",  as: :scrapbook_import
  delete "scrapbook/:id",      to: "scrapbooks#destroy", as: :scrapbook_item
  get    "scrapbook/:id/file", to: "scrapbooks#file",    as: :scrapbook_item_file
  post   "scrapbook/:id/use",  to: "scrapbooks#use",     as: :use_scrapbook_item
  # Copy a scrapbook item into uploads so it can be a job's ARTWORK (the Run Job
  # source). Separate from `:reference` on purpose: a reference must be a RASTER
  # (it goes into a flux edit request as a data URI) while a job's source may be
  # an SVG the pipeline traces, and `:use` redirects to the new-job form, which
  # would discard a form the operator has already filled in.
  post "scrapbook/:id/artwork", to: "scrapbooks#artwork", as: :scrapbook_item_artwork
  # Copy a scrapbook item into uploads so it can be a FLUX reference image (the
  # edit input) — returns JSON, unlike #use which redirects to a new job.
  post   "scrapbook/:id/reference", to: "scrapbooks#reference", as: :scrapbook_item_reference

  # The event log: the recorded human actions (stars, picks, deletes) a later
  # learned-ranker phase trains on. Read-only; the controller enforces the
  # login gate and the rows are owner-scoped to the signed-in operator.
  get    "events", to: "events#index", as: :events

  # REPORT A PROBLEM -- the footer's maintenance button. One POST, no index: an
  # operator FILES a report, they do not come back to read a list of them, and a
  # GET route here would be a page that has to join every head registry for no
  # reader. Login-gated in the controller, like every other authed route here.
  # JSON by default because the caller is the footer popup: it renders the
  # outcome in place so a failed filing never costs the reporter their text.
  post "reports", to: "bug_reports#create", as: :bug_reports, defaults: { format: :json }

  # The system aggregate: the machine-readable twin of the footer's check-engine
  # light. Runner health per label, this owner's recorded event counts by kind,
  # and the ranker's cold/live state -- one JSON document an agent can read
  # instead of probing each sidecar's /health separately. Login-gated; the
  # default format is JSON because that is the only shape it has.
  get    "engine", to: "engine#show", as: :engine, defaults: { format: :json }

  # Composite builder — assemble a job's source raster out of layered pieces.
  #
  # Named helpers, not bare paths: `composites_path` would otherwise resolve to
  # the LIST route and silently POST a create to a GET.
  get  "composite",          to: "composites#show",   as: :composite
  get  "composite/new",      to: "composites#show",   as: :new_composite
  get  "composite/list",     to: "composites#index",   as: :list_composites
  get  "composite/layers",   to: "composites#layers_available", as: :composite_layers
  post "composite",          to: "composites#create",  as: :create_composite
  patch "composite/:id",     to: "composites#update",  as: :composite_update
  post "composite/:id/flatten", to: "composites#flatten", as: :flatten_composite
  # The chain: one call that COMPOSES a composite's vector layers into the stored
  # SVG artefact and records the compose job in the job history, then answers the
  # created artefact + job (201). It does NOT file a trace job — a trace needs a
  # RASTER source and the composed SVG is the compose deliverable, never a trace
  # source. Login- and owner-scoped like the rest of the composite surface.
  post "composite/:id/chain", to: "composites#chain", as: :chain_composite
  # The recipe: the EXACT compose spec (inline SVG for every vector layer) this
  # composite's vector flatten POSTs to the svg runner's /compose — the one
  # contract an agent reads to drive compose -> collect without rebuilding it.
  # Additive, and JSON by default because that is the only shape it has.
  get "composite/:id/recipe", to: "composites#recipe", as: :recipe_composite,
      defaults: { format: :json }
  post "composite/:id/use",  to: "composites#use",     as: :use_composite
  delete "composite/:id",    to: "composites#destroy", as: :delete_composite

  # Sketch: arranging what is on the canvas. `template` states an arrangement
  # once and returns the layers RE-PLACED AND COUPLED — the door an agent uses
  # when nobody is going to drag anything; `metrics` is the read-only twin of
  # the builder's readout, and the surface the heuristic/ML side reads.
  #
  # POST, and given no id it arranges the layers it was HANDED without touching
  # the database, which is what makes it usable from the unsaved builder page.
  post "composite/template",    to: "composites#template", as: :composite_template,
       defaults: { format: :json }
  get  "composite/:id/metrics", to: "composites#metrics",  as: :composite_metrics,
       defaults: { format: :json }

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  get    "up" => "rails/health#show", as: :rails_health_check

   # Projects — the container redesign: a stored table (not a view over tags)
   # that owns sources, sequences jobs, and holds outputs back to the project
   # that asked for them. Tags are two-tier (`kind` column), the sequence
   # counter is on the row (not MAX+1), and `is_test` is real.
   resources :projects, only: %i[index show new create]
end
