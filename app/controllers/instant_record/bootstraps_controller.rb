module InstantRecord
  # First-sync hydration: current state (shaped via sync_shape or windowed via
  # sync_window) plus the change-log cursor, so a fresh client never replays
  # the whole change log. The cursor is read BEFORE the rows, inside one
  # transaction: events committed between cursor and response re-apply
  # idempotently client-side, whereas the reverse order would skip them.
  class BootstrapsController < ActionController::API
    before_action { headers.merge!(InstantRecord::CORS_HEADERS) }
    rescue_from InstantRecord::Unauthorized, with: -> { head :unauthorized }
    rescue_from InstantRecord::Forbidden, with: -> { head :forbidden }

    def preflight
      head :no_content
    end

    def show
      SyncScope.authenticate!(request)
      identity = SyncScope.identity(request)
      partition = SyncScope.partition(request, identity)
      models = bootstrap_models(partition)
      SyncScope.authorize_models!(models, partition, identity, request)

      payload = ActiveRecord::Base.transaction do
        cursor = Change.maximum(:id) || 0
        { cursor: cursor, records: models.flat_map { |model| serialize_rows(model, identity, partition) } }
      end
      fill = models.filter_map do |model|
        shape = model.instant_record_sync_shape
        shape&.fill_descriptor(partition: SyncScope.partition_value(model, partition))
      end
      payload[:fill] = fill if fill.any?
      # The key a client keeps and sends back, so the server notices when the
      # person behind the browser or active partition changes.
      payload[:identity] = SyncScope.key(identity, partition: partition)
      headers["cache-control"] = "no-store"
      render json: payload
    end

    private

    # Eager-load first so development doesn't miss lazily-loaded models;
    # SyncScope.models_for selects unpartitioned models by default, or matching
    # partitioned models when a partition is requested.
    def bootstrap_models(partition)
      Rails.application.eager_load! unless Rails.application.config.eager_load
      SyncScope.models_for(partition)
    end

    def serialize_rows(model, identity, partition)
      base = SyncScope.visible(model, identity, partition: partition)
      if (shape = model.instant_record_sync_shape)
        shape.bootstrap_records(base).map { |record| InstantRecord.record_payload(record) }
      elsif (window = model.instant_record_sync_window)
        window.in_window.merge(base).map { |record| InstantRecord.record_payload(record) }
      else
        base.map { |record| InstantRecord.record_payload(record) }
      end
    end
  end
end
