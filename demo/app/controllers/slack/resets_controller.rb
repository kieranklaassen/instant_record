module Slack
  # Restores the Slack demo to its seeded state. Must run on the real server:
  # only the server's change log propagates, so every destroy and reseeded
  # create is logged and connected browsers converge over SSE. API-style like
  # the gem's own sync endpoints — the PWA posts here cross-origin, so there
  # is no CSRF token and the response needs CORS headers.
  class ResetsController < ActionController::API
    before_action { headers.merge!(InstantRecord::CORS_HEADERS) }

    def preflight
      head :no_content
    end

    def create
      seed_ids = Slack::Seeds.seed_ids

      ActiveRecord::Base.transaction do
        Message.destroy_all
        Channel.where.not(id: seed_ids[:channels]).destroy_all
        ChatUser.where.not(id: seed_ids[:users]).destroy_all
        Slack::Seeds.apply
      end

      head :no_content
    end
  end
end
