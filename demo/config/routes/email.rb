get "email", to: "email/mailboxes#index"
post "email", to: "email/mailboxes#create"
scope "email/sync/:member/:inbox", controller: "email/sync" do
  get "bootstrap", action: :bootstrap
  get "events", action: :events
  post "mutations", action: :mutations
  match "mutations", action: :preflight, via: :options
end
