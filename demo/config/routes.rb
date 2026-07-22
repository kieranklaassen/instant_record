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

  # Note: the deployed PWA's static index.html shadows root when served from
  # public/ (ActionDispatch::Static wins); in the browser runtime all fetches
  # go through Rack, so this root is what visitors see.
  root "todo/issues#index"
end
