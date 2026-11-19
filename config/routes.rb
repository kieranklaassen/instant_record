InstantRecord::Engine.routes.draw do
  post "mutations", to: "mutations#create"
  match "mutations", to: "mutations#preflight", via: :options
  get "events", to: "events#index"
  get "bootstrap", to: "bootstraps#show"
  get "records", to: "records#index"
  # A native app's screens while developing. Answers 404 unless the app set
  # config.instant_record.native_dev, in a local environment, to this machine.
  post "native/render", to: "native_screens#show"
  post "native/action", to: "native_screens#perform"
end
