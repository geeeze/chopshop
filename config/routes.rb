Rails.application.routes.draw do
  root "jobs#index"

  get    "login",  to: "application#login"
  post   "login",  to: "application#authenticate"
  delete "logout", to: "application#logout"

  # spec builder + info pages
  get  "json",     to: "pages#schema",     as: :json
  post "json/use", to: "pages#apply_spec", as: :use_json
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
  # STATUS — the ML telemetry surface: the candidate-triage learning signal as a
  # hierarchy (source → job → candidate) plus its recorded event log, drawn by
  # chopshop-plot's tree and log operations. A reference page like PLOT, and last
  # in the nav because it reports what the four beside it configure.
  get  "status",   to: "pages#status",     as: :status

  # TOURNAMENT -- a SIMULATED bracket over a candidate set, and the reference for
  # the mirrored (two-sided) layout: the tree folded at its ROOT with the final
  # in the CENTRE column and round one at both outer edges. It decides nothing;
  # the pipeline never picks a winner, and this is where that rule is
  # demonstrated rather than broken. A reference page like STATUS, after it.
  get  "tournament", to: "pages#tournament", as: :tournament

  resources :jobs, only: %i[index show new create] do
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
  get "up" => "rails/health#show", as: :rails_health_check
end
