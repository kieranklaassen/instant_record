require "instant_record/sync_endpoint"

module InstantRecord
  class MutationsController < ActionController::API
    include SyncEndpoint

    # Accepts a batch of client mutations; MutationApplier owns the sync
    # semantics (idempotency, LWW, versioning, change logging).
    def create
      # Who is asking may come from a session cookie, so this endpoint must not
      # take a cross-site form post: a form cannot send JSON.
      return head :unsupported_media_type unless request.content_mime_type&.json?

      SyncScope.authenticate!(request)
      identity = SyncScope.identity(request)
      partition = SyncScope.partition(request, identity)
      eager_load_models!
      SyncScope.authorize_models!(SyncScope.models_for(partition), partition, identity, request)

      batch = params.require(:mutations)
      return head :bad_request unless batch.is_a?(Array) && batch.all? { |item| item.is_a?(ActionController::Parameters) }

      # Writes to scoped records that were queued as someone else are refused.
      # They are not written to the ledger: the client drops them when its next
      # poll tells it to reset.
      stale = SyncScope.stale?(params[:identity], identity, partition: partition) ? SyncScope.reset_types(identity, partition: partition) : []
      permitted = batch.map { |raw| permit_mutation(raw) }

      # Offline creates can share a timestamp; apply parents before children
      # that reference them in the same batch while preserving response order.
      applied = {}
      order_by_dependency(permitted).each do |index, mutation|
        owner_type = mutation[:record_type].presence ||
          (mutation[:mutator].present? ? SyncActions.owner_type_of(mutation[:mutator].to_s) : nil)
        mutation_id = mutation[:mutation_id] || mutation[:id]
        applied[index] =
          if owner_type && stale.include?(owner_type)
            { mutation_id: mutation_id, status: "rejected", reason: "identity changed" }
          else
            MutationApplier.apply(mutation, identity, partition)
          end
      end

      results = permitted.each_index.map { |index| applied[index] }
      render json: { results: results, server_time: InstantRecord::HLC.iso_now }
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

    def permit_mutation(raw)
      if raw[:mutator].present? || raw[:operation].to_s == "mutator"
        base = raw.permit(:id, :mutation_id, :record_type, :record_id, :operation, :mutator).to_h.symbolize_keys
        base[:args] = sanitize_json_value(raw[:args]) || {}
        base
      else
        raw.permit(:id, :record_type, :record_id, :operation, :base_version, :hlc, :schema_version, changes: {})
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
