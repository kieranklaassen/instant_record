get "assistant", to: "assistant/chats#index"
get "assistant/history", to: "assistant/history#index"
post "assistant/replies", to: "assistant/replies#create"
match "assistant/replies", to: "assistant/replies#preflight", via: :options
