module InstantRecord
  # Rails routing DSL extension for declaring local-first islands directly in
  # config/routes.rb (and draw'n config/routes/*.rb files).
  #
  # On the Rails server, `local_first` yields transparently so every route draws
  # and generates URL helpers identically. At compile time, the Prism route
  # analyzer reads these blocks statically to stage only reachable controllers,
  # models, views, helpers, and migrations.
  #
  #   Rails.application.routes.draw do
  #     local_first do
  #       namespace :todo do
  #         resources :issues, only: [:create, :update, :destroy]
  #         root "issues#index"
  #       end
  #     end
  #   end
  #
  # Optional island name and explicit overrides for dynamic Ruby patterns:
  #
  #   local_first(:inbox, include: { models: ["PriorityMail"], partials: ["shared/row"] }) do
  #     get "email", to: "email/mailboxes#index"
  #   end
  module Routing
    def local_first(_name = nil, include: nil, server_routes: nil, &block)
      yield if block
    end
  end
end

if defined?(ActionDispatch::Routing::Mapper) && !ActionDispatch::Routing::Mapper.include?(InstantRecord::Routing)
  ActionDispatch::Routing::Mapper.include(InstantRecord::Routing)
end
