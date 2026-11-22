Rails.application.routes.draw do
  # InstantRecord::Engine auto-mounts at /instant_record (see the gem's railtie).

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # The service worker that keeps the app shell (app/views/pwa/service-worker.js).
  # The page registers /service-worker.js; the compiled build copies the same
  # file to that path on its static site.
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Each demo app lives under its own namespace: controllers in
  # app/controllers/<demo>/, views in app/views/<demo>/, routes scoped here.
  local_first do
    namespace :todo do
      resources :issues, only: [:create, :update, :destroy]
      root "issues#index" # /todo
    end
  end

  namespace :slack do
    local_first do
      resources :channels, only: [:show]
      resources :messages, only: [:create]
      root "channels#index" # /slack
    end
    post "reset", to: "resets#create"
    match "reset", to: "resets#preflight", via: :options
  end

  # Demos added after the first two keep their routes in config/routes/<demo>.rb
  # so each one is edited in isolation.
  draw(:migrate)
  draw(:receipts)
  draw(:console)
  draw(:email)
  draw(:assistant)
  draw(:auth)
  draw(:compare)

  # The deployed PWA's static index.html (boot splash) shadows root when
  # served from public/ (ActionDispatch::Static wins). In the browser runtime
  # all fetches go through Rack, so this root is what visitors see there;
  # /home reaches the same page on the server.
  local_first do
    get "home", to: "home#index"
    root "home#index"
  end
end
