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
  # Import a raw PNG/JPEG (an edited scrape from the sidebar's canvas editor)
  # as a new scrapbook item.
  post   "scrapbook/import",   to: "scrapbooks#import",  as: :scrapbook_import
  delete "scrapbook/:id",      to: "scrapbooks#destroy", as: :scrapbook_item
  get    "scrapbook/:id/file", to: "scrapbooks#file",    as: :scrapbook_item_file
  post   "scrapbook/:id/use",  to: "scrapbooks#use",     as: :use_scrapbook_item

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
  post "composite/:id/use",  to: "composites#use",     as: :use_composite
  delete "composite/:id",    to: "composites#destroy", as: :delete_composite

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  get "up" => "rails/health#show", as: :rails_health_check
end
