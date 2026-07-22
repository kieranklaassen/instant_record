module InstantRecord
  class MutationsController < ActionController::API
    before_action { headers.merge!(InstantRecord::CORS_HEADERS) }

    def preflight
      head :no_content
    end

    # Accepts a batch of client mutations; MutationApplier owns the sync
    # semantics (idempotency, LWW, versioning, change logging).
    def create
      results = Array(params.require(:mutations)).map do |raw|
        MutationApplier.apply(
          raw.permit(:id, :record_type, :record_id, :operation, :base_version, changes: {})
        )
      end

      render json: { results: results }
    end
  end
end
