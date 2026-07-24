# Demo 04 — a migration applied to a local database that already holds rows
# (and undrained outbox mutations).
namespace :migrate do
  root "notes#index" # /migrate

  resources :notes, only: [:create]

  # Run the pending migration against this browser's existing store, and undo it
  # so the demo can be watched more than once.
  post "ship", to: "releases#create"
  delete "ship", to: "releases#destroy"
end
