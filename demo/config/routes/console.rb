# Proof that the models really do run here: a REPL against this runtime, and the
# source of whatever page you are looking at, read out of the packed bundle.
namespace :console do
  root "sessions#index" # /console
  post "eval", to: "sessions#create"
end

get "source", to: "source#show", as: :source
