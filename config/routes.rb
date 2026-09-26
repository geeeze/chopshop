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

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  get "up" => "rails/health#show", as: :rails_health_check
end
