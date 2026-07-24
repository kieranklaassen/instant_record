Rails.application.routes.draw do
  # InstantRecord::Engine auto-mounts at /instant_record (see the gem's railtie).

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Each demo app lives under its own namespace: controllers in
  # app/controllers/<demo>/, views in app/views/<demo>/, routes scoped here.
  namespace :todo do
    resources :issues, only: [:create, :update, :destroy]
    root "issues#index" # /todo
  end

  namespace :slack do
    resources :channels, only: [:show]
    resources :messages, only: [:create]
    post "reset", to: "resets#create"
    match "reset", to: "resets#preflight", via: :options
    root "channels#index" # /slack
  end

  # Demos added after the first two keep their routes in config/routes/<demo>.rb
  # so each one is edited in isolation.
  draw(:migrate)
  draw(:receipts)
  draw(:console)

  # The deployed PWA's static index.html (boot splash) shadows root when
  # served from public/ (ActionDispatch::Static wins). In the browser runtime
  # all fetches go through Rack, so this root is what visitors see there;
  # /home reaches the same page on the server.
  get "home", to: "home#index"
  root "home#index"
end
