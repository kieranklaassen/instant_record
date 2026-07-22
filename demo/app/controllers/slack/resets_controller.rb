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
        # Visitor-era rows only: seeded welcomes and the backfill history
        # survive (matched by id prefix, so the sweep never carries a
        # thousands-long id list). destroy_all deletes a set of rows loaded
        # up front, so a fake reply committed while the sweep is blocked on
        # FakeReplyJob's row lock would survive a single pass. Re-sweep until
        # none remain: once every row is deleted, pending reply jobs block on
        # our locks and bail out when their message is gone.
        swept = Message.where.not(id: seed_ids[:messages]).where.not("id LIKE 'backfill-%'")
        swept.destroy_all while swept.exists?
        Channel.where.not(id: seed_ids[:channels]).destroy_all
        ChatUser.where.not(id: seed_ids[:users]).destroy_all
        Slack::Seeds.apply
      end

      head :no_content
    end
  end
end
