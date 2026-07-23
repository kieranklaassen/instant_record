module InstantRecord
  # First-sync hydration: current state (windowed per model when a sync_window
  # is declared) plus the change-log cursor, so a fresh client never replays
  # the whole change log. The cursor is read BEFORE the rows, inside one
  # transaction: events committed between cursor and response re-apply
  # idempotently client-side, whereas the reverse order would skip them.
  class BootstrapsController < ActionController::API
    before_action { headers.merge!(InstantRecord::CORS_HEADERS) }

    def show
      payload = ActiveRecord::Base.transaction do
        cursor = Change.maximum(:id) || 0
        { cursor: cursor, records: bootstrap_models.flat_map { |model| serialize_rows(model) } }
      end
      render json: payload
    end

    private

    # Eager-load first so development doesn't miss lazily-loaded models;
    # syncable_models then resolves like synced_model (allowlist or all
    # Syncable includers).
    def bootstrap_models
      Rails.application.eager_load! unless Rails.application.config.eager_load
      InstantRecord.syncable_models
    end

    def serialize_rows(model)
      window = model.instant_record_sync_window
      scope = window ? window.in_window : model.all
      scope.map { |record| InstantRecord.record_payload(record) }
    end
  end
end
