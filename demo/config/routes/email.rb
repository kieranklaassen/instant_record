local_first do
  get "email", to: "email/mailboxes#index"
  post "email", to: "email/mailboxes#create"
end
post "email/incoming", to: "email/incoming#create"
match "email/incoming", to: "email/incoming#preflight", via: :options
get "email/shell", to: "email/shells#show"
get "email/shell/file", to: "email/shells#file"
