namespace :assistant do
  resources :turns, only: [:create, :update]
  root "turns#index" # /assistant
end
