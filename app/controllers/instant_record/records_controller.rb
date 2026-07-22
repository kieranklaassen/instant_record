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

      before_at = Time.zone.parse(params[:before_created_at].to_s)
      return head :bad_request if before_at.nil? || params[:before_id].blank?

      limit = (params[:limit].presence || window.limit).to_i.clamp(1, HARD_LIMIT)
      rows = page(model, window, before_at, limit)

      render json: {
        records: rows.first(limit).map { |record| serialize(model, record) },
        has_more: rows.size > limit
      }
    end

    private

    def page(model, window, before_at, limit)
      pk = model.primary_key
      scope = window.partition_by ? model.where(window.partition_by => params[:partition]) : model.all
      scope
        .where("created_at < :at OR (created_at = :at AND #{pk} < :id)", at: before_at, id: params[:before_id])
        .order(created_at: :desc, pk => :desc)
        .limit(limit + 1)
        .to_a
    end

    def serialize(model, record)
      {
        type: model.name,
        id: record.id,
        version: record[:server_version],
        attributes: record.attributes.except("sync_state")
      }
    end
  end
end
