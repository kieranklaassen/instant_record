# The Auth demo: a real session, three people, and notes that only the right
# people's browsers are sent.
namespace :auth do
  local_first do
    root "notes#index" # /auth

    resources :notes, only: [:create, :destroy]
  end

  # The session lives on the server and nowhere else. The page asks for it,
  # sets it and clears it over JSON, from whichever runtime drew the page.
  get "session", to: "sessions#show"
  post "session", to: "sessions#create"
  post "session/sign_out", to: "sessions#destroy"
end
