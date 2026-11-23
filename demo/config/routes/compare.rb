# One todo list, four ways. Each way is a whole small app in its own namespace,
# with its own list, so they can be read and timed side by side:
#
#   /plain    what `rails new` gives: forms, a redirect, a page
#   /hotwire  Turbo Streams: the server answers with the piece that changed
#   /inertia  Inertia and React, drawing the change before the server answers
#   /instant  the plain app again, compiled to run in the browser by InstantRecord
#
# /compare puts the four next to each other with a stopwatch on each.
%i[plain hotwire inertia].each do |way|
  namespace way do
    resources :todos, only: [:create, :update, :destroy]
    root "todos#index"
  end
end

local_first do
  namespace :instant do
    resources :todos, only: [:create, :update, :destroy]
    root "todos#index"
  end
end

get "compare", to: "compare#index"
post "compare/reset", to: "compare#reset"
