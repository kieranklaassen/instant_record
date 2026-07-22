module InstantRecord
  # A bounded sync window declared on a Syncable model: the newest `limit`
  # rows, per partition when partition_by is set, ordered by (created_at, id).
  # Bootstrap serializes in_window, history pages walk below it, and the
  # browser client evicts beyond_window at boot.
  class SyncWindow
    attr_reader :model, :limit, :partition_by

    def initialize(model, limit:, partition_by: nil)
      unless limit.is_a?(Integer) && limit.positive?
        raise ArgumentError, "sync_window limit must be a positive integer (got #{limit.inspect})"
      end

      @model = model
      @limit = limit
      @partition_by = partition_by&.to_s
    end

    # Rows inside the window (the newest `limit` per partition).
    def in_window
      @model.where("#{quoted_primary_key} IN (#{ranked_ids_sql("<=")})")
    end

    # Rows outside the window — eviction's target. An extra `scope` narrows
    # further (e.g. excluding sync_state "pending").
    def beyond_window(scope = @model.all)
      scope.where("#{quoted_primary_key} IN (#{ranked_ids_sql(">")})")
    end

    private

    # ROW_NUMBER() runs identically on Postgres, PGlite, and SQLite >= 3.25 —
    # the three engines the same model file can find itself on.
    def ranked_ids_sql(comparison)
      validate_columns!
      connection = @model.connection
      table = connection.quote_table_name(@model.table_name)
      created_at = connection.quote_column_name("created_at")
      over = [partition_clause(connection), "ORDER BY #{created_at} DESC, #{quoted_primary_key} DESC"].compact.join(" ")

      <<~SQL.squish
        SELECT #{quoted_primary_key} FROM (
          SELECT #{quoted_primary_key}, ROW_NUMBER() OVER (#{over}) AS instant_record_rank
          FROM #{table}
        ) instant_record_ranked
        WHERE instant_record_rank #{comparison} #{@limit}
      SQL
    end

    def partition_clause(connection)
      @partition_by && "PARTITION BY #{connection.quote_column_name(@partition_by)}"
    end

    def quoted_primary_key
      @model.connection.quote_column_name(@model.primary_key)
    end

    # Deferred to first use: at declaration time the table may not exist yet
    # (class load precedes migrations).
    def validate_columns!
      return if @validated

      %w[created_at].concat([@partition_by].compact).each do |column|
        unless @model.column_names.include?(column)
          raise ArgumentError, "sync_window column #{column.inspect} does not exist on #{@model.table_name}"
        end
      end
      @validated = true
    end
  end
end
