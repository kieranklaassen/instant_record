module InstantRecord
  class MutationsController < ActionController::API
    before_action { headers.merge!(InstantRecord::CORS_HEADERS) }

    def preflight
      head :no_content
    end

    # Accepts a batch of client mutations; MutationApplier owns the sync
    # semantics (idempotency, LWW, versioning, change logging).
    def create
      # Who is asking may come from a session cookie, so this endpoint must not
      # take a cross-site form post: a form cannot send JSON.
      return head :unsupported_media_type unless request.content_mime_type&.json?

      identity = SyncScope.identity(request)
      # Writes to scoped records that were queued as someone else are refused.
      # They are not written to the ledger: the client drops them when its next
      # poll tells it to reset.
      stale = SyncScope.stale?(params[:identity], identity) ? SyncScope.reset_types(identity) : []
      results = Array(params.require(:mutations)).map do |raw|
        mutation = raw.permit(:id, :record_type, :record_id, :operation, :base_version, changes: {})
        if stale.include?(mutation[:record_type])
          { mutation_id: mutation[:id], status: "rejected", reason: "identity changed" }
        else
          MutationApplier.apply(mutation, identity)
        end
      end

      render json: { results: results }
    end
  end
end
