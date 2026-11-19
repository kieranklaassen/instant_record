module InstantRecord
  class MutationsController < ActionController::API
    before_action { headers.merge!(InstantRecord::CORS_HEADERS) }

    def preflight
      head :no_content
    end

    # Accepts a batch of client mutations; MutationApplier owns the sync
    # semantics (idempotency, LWW, versioning, change logging).
    def create
      # With identities configured this endpoint is authenticated by the session
      # cookie, so it must not take a cross-site form post: a form cannot send JSON.
      return head :unsupported_media_type if SyncScope.enabled? && !request.content_mime_type&.json?

      identity = SyncScope.identity(request)
      mutations = Array(params.require(:mutations)).map do |raw|
        raw.permit(:id, :record_type, :record_id, :operation, :base_version, changes: {})
      end

      # Writes queued as someone else are refused whole. They are not written to
      # the ledger: the client drops them when its next poll tells it to reset.
      # A client that names no identity queued nothing as anyone, and is judged
      # by who it is now.
      results =
        if params[:identity].present? && SyncScope.stale?(params[:identity], identity)
          mutations.map { |mutation| { mutation_id: mutation[:id], status: "rejected", reason: "identity changed" } }
        else
          mutations.map { |mutation| MutationApplier.apply(mutation, identity) }
        end

      render json: { results: results }
    end
  end
end
