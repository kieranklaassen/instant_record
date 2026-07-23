module InstantRecord
  # Keyset-cursor history pages for windowed models: rows strictly below the
  # (created_at, id) tuple, newest first. Backs InstantRecord.fetch_history;
  # never uses OFFSET, so page cost stays flat at any depth.
  class RecordsController < ActionController::API
    # Independent of any model's window size: the ceiling a client can
    # request in one page.
    HARD_LIMIT = 200

    before_action { headers.merge!(InstantRecord::CORS_HEADERS) }

    def index
      model = InstantRecord.synced_model(params[:type])
      return head :not_found unless model

      window = model.instant_record_sync_window
      return head :unprocessable_entity unless window
      return head :bad_request if window.partition_by && params[:partition].blank?

      before_at = parse_time(params[:before_created_at])
      return head :bad_request if before_at.nil? || params[:before_id].blank?

      limit = (params[:limit].presence || window.limit).to_i.clamp(1, HARD_LIMIT)
      rows = window
        .keyset_below(at: before_at, id: params[:before_id], partition: params[:partition])
        .limit(limit + 1)
        .to_a

      render json: {
        records: rows.first(limit).map { |record| InstantRecord.record_payload(record) },
        has_more: rows.size > limit
      }
    end

    private

    # Time.zone.parse returns nil for unparseable input but raises
    # ArgumentError for out-of-range components ("25:61"); treat both as a bad
    # cursor so a crafted param is a 400, not a 500.
    def parse_time(value)
      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
