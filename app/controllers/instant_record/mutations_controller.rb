module InstantRecord
  class MutationsController < ActionController::API
    before_action { headers.merge!(InstantRecord::CORS_HEADERS) }
    rescue_from InstantRecord::Unauthorized, with: -> { head :unauthorized }
    rescue_from InstantRecord::Forbidden, with: -> { head :forbidden }

    def preflight
      head :no_content
    end

    # Accepts a batch of client mutations; MutationApplier owns the sync
    # semantics (idempotency, LWW, versioning, change logging).
    def create
      # Who is asking may come from a session cookie, so this endpoint must not
      # take a cross-site form post: a form cannot send JSON.
      return head :unsupported_media_type unless request.content_mime_type&.json?

      SyncScope.authenticate!(request)
      identity = SyncScope.identity(request)
      partition = SyncScope.partition(request, identity)
      Rails.application.eager_load! if defined?(Rails) && Rails.application && !Rails.application.config.eager_load
      SyncScope.authorize_models!(SyncScope.models_for(partition), partition, identity, request)

      batch = params.require(:mutations)
      return head :bad_request unless batch.is_a?(Array) && batch.all? { |item| item.is_a?(ActionController::Parameters) }

      # Writes to scoped records that were queued as someone else are refused.
      # They are not written to the ledger: the client drops them when its next
      # poll tells it to reset.
      stale = SyncScope.stale?(params[:identity], identity, partition: partition) ? SyncScope.reset_types(identity, partition: partition) : []
      permitted = batch.map { |raw| raw.permit(:id, :record_type, :record_id, :operation, :base_version, changes: {}) }

      # Offline creates can share a timestamp; apply parents before children
      # that reference them in the same batch while preserving response order.
      applied = {}
      order_by_dependency(permitted).each do |index, mutation|
        applied[index] =
          if stale.include?(mutation[:record_type])
            { mutation_id: mutation[:id], status: "rejected", reason: "identity changed" }
          else
            MutationApplier.apply(mutation, identity, partition)
          end
      end

      render json: { results: permitted.each_index.map { |index| applied[index] } }
    end

    private

    # Places creates whose record_id is referenced by another create's
    # parent_id (or parent_message_id) in the same batch ahead of dependents.
    def order_by_dependency(mutations)
      indexed = mutations.each_with_index.map { |mutation, index| [index, mutation] }
      created_ids = indexed.each_with_object({}) do |(_, mutation), map|
        map[mutation[:record_id].to_s] = true if mutation[:operation] == "create" && mutation[:record_id].present?
      end
      return indexed if created_ids.size < 2

      dependents, roots = indexed.partition do |_, mutation|
        next false unless mutation[:operation] == "create"

        changes = mutation[:changes]
        next false unless changes

        parent = changes[:parent_id].presence || changes[:parent_message_id].presence
        parent && parent.to_s != mutation[:record_id].to_s && created_ids.key?(parent.to_s)
      end
      roots + dependents
    end
  end
end
