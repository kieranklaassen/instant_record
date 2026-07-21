InstantRecord::Engine.routes.draw do
  post "mutations", to: "mutations#create"
  get "events", to: "events#index"
end
