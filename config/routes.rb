InstantRecord::Engine.routes.draw do
  post "mutations", to: "mutations#create"
  match "mutations", to: "mutations#preflight", via: :options
  get "events", to: "events#index"
  get "bootstrap", to: "bootstraps#show"
  get "records", to: "records#index"
  # The bytes of a record that declares sync_file. A type may be namespaced
  # and an id may hold a dot, so neither is cut at one.
  constraints type: %r{[^/]+}, id: %r{[^/]+} do
    get "files/:type/:id/upload", to: "files#progress"
    get "files/:type/:id", to: "files#show"
    put "files/:type/:id", to: "files#update"
    match "files/:type/:id", to: "files#preflight", via: :options
  end
  # A native app's screens while developing. Answers 404 unless the app set
  # config.instant_record.native_dev, in a local environment, to this machine.
  post "native/render", to: "native_screens#show"
  post "native/action", to: "native_screens#perform"
end
