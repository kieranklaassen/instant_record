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
        mutation = permit_mutation(raw)
        owner_type = mutation[:record_type].presence ||
          (mutation[:mutator].present? ? SyncActions.owner_type_of(mutation[:mutator].to_s) : nil)
        mutation_id = mutation[:mutation_id] || mutation[:id]
        if owner_type && stale.include?(owner_type)
          { mutation_id: mutation_id, status: "rejected", reason: "identity changed" }
        else
          MutationApplier.apply(mutation, identity)
        end
      end

      render json: { results: results }
    end

    private

    def permit_mutation(raw)
      if raw[:mutator].present? || raw[:operation].to_s == "mutator"
        base = raw.permit(:id, :mutation_id, :record_type, :record_id, :operation, :mutator).to_h.symbolize_keys
        base[:args] = sanitize_json_value(raw[:args]) || {}
        base
      else
        raw.permit(:id, :record_type, :record_id, :operation, :base_version, :schema_version, changes: {})
      end
    end

    def sanitize_json_value(value)
      case value
      when ActionController::Parameters
        value.to_unsafe_h.each_with_object({}) { |(k, v), out| out[k.to_s] = sanitize_json_value(v) }
      when Hash
        value.each_with_object({}) { |(k, v), out| out[k.to_s] = sanitize_json_value(v) }
      when Array
        value.map { |item| sanitize_json_value(item) }
      when String, Integer, Float, TrueClass, FalseClass, NilClass
        value
      else
        value.to_s
      end
    end
  end
end
