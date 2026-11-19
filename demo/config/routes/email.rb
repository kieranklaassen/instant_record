get "email", to: "email/mailboxes#index"
post "email", to: "email/mailboxes#create"
scope "email/sync/:member/:inbox", controller: "email/sync" do
  get "records", action: :records
  get "bootstrap", action: :bootstrap
  get "shell", action: :shell
  get "shell/file", action: :shell_file
  post "incoming", action: :incoming
  match "incoming", action: :preflight, via: :options
  get "events", action: :events
  post "mutations", action: :mutations
  match "mutations", action: :preflight, via: :options
end
