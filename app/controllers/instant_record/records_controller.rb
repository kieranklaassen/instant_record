module InstantRecord
  # Keyset-cursor history pages, search widening, and single-record lookups for
  # shaped (`sync_shape`) and windowed (`sync_window`) models. Never uses
  # OFFSET, so page cost stays flat at any depth.
  class RecordsController < ActionController::API
    # Independent of any model's window size: the ceiling a client can
    # request in one page.
    HARD_LIMIT = 200

    before_action { headers.merge!(InstantRecord::CORS_HEADERS) }
    rescue_from InstantRecord::Unauthorized, with: -> { head :unauthorized }
    rescue_from InstantRecord::Forbidden, with: -> { head :forbidden }

    def preflight
      head :no_content
    end

    def index
      SyncScope.authenticate!(request)
      identity = SyncScope.identity(request)
      partition = SyncScope.partition(request, identity)
      Rails.application.eager_load! unless Rails.application.config.eager_load

      model = resolve_model(partition)
      return head :not_found unless model

      if SyncScope.partitioned?(model)
        part_value = SyncScope.partition_value(model, partition)
        return head :forbidden if part_value.nil?

        SyncScope.authorize_partition!(model, part_value, identity, request)
      end

      base = SyncScope.visible(model, identity, partition: partition)
      if (shape = model.instant_record_sync_shape)
        return render_shape(shape, base)
      end

      window = model.instant_record_sync_window
      return head :unprocessable_entity unless window
      return head :bad_request if window.partition_by && params[:partition].blank?

      before_at = parse_time(params[:before_created_at])
      return head :bad_request if before_at.nil? || params[:before_id].blank?

      limit = (params[:limit].presence || window.limit).to_i.clamp(1, HARD_LIMIT)
      rows = window
        .keyset_below(at: before_at, id: params[:before_id], partition: params[:partition], scope: base)
        .limit(limit + 1)
        .to_a

      page = rows.first(limit)
      last = page.last
      payload = {
        records: page.map { |record| InstantRecord.record_payload(record) },
        has_more: rows.size > limit
      }
      if last
        payload[:next_before] = {
          created_at: last.created_at.utc.iso8601(InstantRecord::TIME_PRECISION),
          id: last.id
        }
      end
      render json: payload
    end

    private

    def resolve_model(partition)
      return InstantRecord.synced_model(params[:type]) if params[:type].present?
      return nil if partition.nil?

      models = SyncScope.models_for(partition)
      models.one? ? models.first : nil
    end

    def render_shape(shape, base)
      lookup_id = params[:id].presence || params[:lookup].presence || params[:thread].presence
      if lookup_id
        rows = shape.lookup(base, lookup_id)
        return render json: { records: rows.map { |record| InstantRecord.record_payload(record) }, has_more: false }
      end

      searching = params[:search].present?
      return head :bad_request unless searching || params[:before_id].present?
      return head :bad_request if searching && !shape.searchable?

      before_at = nil
      if params[:before_id].present?
        before_at = parse_time(params[:before_created_at])
        return head :bad_request if before_at.nil?
      end

      result = shape.page(
        base,
        before_at: before_at,
        before_id: params[:before_id].presence,
        limit: params[:limit].presence,
        search: params[:search].presence
      )
      payload = {
        records: result[:records].map { |record| InstantRecord.record_payload(record) },
        has_more: result[:has_more]
      }
      payload[:next_before] = result[:next_before] if result[:next_before]
      render json: payload
    end

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
