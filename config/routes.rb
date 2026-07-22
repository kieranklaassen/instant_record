InstantRecord::Engine.routes.draw do
  post "mutations", to: "mutations#create"
  match "mutations", to: "mutations#preflight", via: :options
  get "events", to: "events#index"
  get "bootstrap", to: "bootstraps#show"
  get "records", to: "records#index"
end
