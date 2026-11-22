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

    # Rows inside the window (the newest `limit` per partition), ranked
    # strictly within `scope`.
    def in_window(scope = @model.all)
      window_relation("<=", scope)
    end

    # Rows outside the window — eviction's target, ranked strictly within
    # `scope` (e.g. excluding sync_state "pending").
    def beyond_window(scope = @model.all)
      window_relation(">", scope)
    end

    # Keyset page scope: rows strictly below the (created_at, id) tuple within
    # one partition, newest first. Shared by the records endpoint (server) and
    # the client's local-page checks — one predicate, no OFFSET.
    def keyset_below(at:, id:, partition: nil, scope: @model.all)
      validate_columns!
      scope ||= @model.all
      return @model.none if null_relation?(scope)

      pk = @model.primary_key
      created_at = "#{quoted_table_name}.#{@model.connection.quote_column_name("created_at")}"
      rows = keyset_base(scope)
      rows = rows.where(@partition_by => partition) if @partition_by
      rows = rows.where("(#{created_at} < :at OR (#{created_at} = :at AND #{qualified_primary_key} < :id))", at: at, id: id)
      rows.respond_to?(:reorder) ? rows.reorder(created_at: :desc, pk => :desc) : rows.order(created_at: :desc, pk => :desc)
    end

    private

    def window_relation(comparison, scope)
      validate_columns!
      scope ||= @model.all
      return @model.none if null_relation?(scope)

      unscoped_model.where("#{qualified_primary_key} IN (#{ranked_ids_sql(comparison, scope)})")
    end

    # ROW_NUMBER() runs identically on Postgres and SQLite >= 3.25 —
    # the three engines the same model file can find itself on.
    def ranked_ids_sql(comparison, scope)
      connection = @model.connection
      table = quoted_table_name
      created_at = connection.quote_column_name("created_at")
      over = [partition_clause(connection), "ORDER BY #{created_at} DESC, #{quoted_primary_key} DESC"].compact.join(" ")
      filter = scope_filter_sql(scope, table)

      <<~SQL.squish
        SELECT #{quoted_primary_key} FROM (
          SELECT #{quoted_primary_key}, ROW_NUMBER() OVER (#{over}) AS instant_record_rank
          FROM #{table}
          #{filter}
        ) instant_record_ranked
        WHERE instant_record_rank #{comparison} #{@limit}
      SQL
    end

    def scope_filter_sql(scope, table)
      ids_sql = scope_ids_sql(scope)
      return "WHERE 1 = 0" if ids_sql.empty?
      return "" if ids_sql == "SELECT #{qualified_primary_key} FROM #{table}"

      "WHERE #{qualified_primary_key} IN (#{ids_sql})"
    end

    def scope_ids_sql(scope)
      if scope.respond_to?(:reselect)
        if scope.limit_value || scope.offset_value
          if scope.distinct_value || scope.order_values.any?
            return "SELECT #{quoted_primary_key} FROM (#{scope.to_sql}) instant_record_scope"
          end

          scope.reselect(qualified_primary_key).to_sql
        else
          scope.reorder(nil).reselect(qualified_primary_key).to_sql
        end
      else
        sql = scope.to_sql
        sql.empty? ? "" : "SELECT #{quoted_primary_key} FROM (#{sql}) instant_record_scope"
      end
    end

    def keyset_base(scope)
      if scope.respond_to?(:joins_values) && complex_scope?(scope)
        ids_sql = scope_ids_sql(scope)
        return @model.none if ids_sql.empty?

        unscoped_model.where("#{qualified_primary_key} IN (#{ids_sql})")
      else
        scope
      end
    end

    def complex_scope?(scope)
      scope.joins_values.any? ||
        scope.left_outer_joins_values.any? ||
        scope.select_values.any? ||
        scope.group_values.any? ||
        scope.distinct_value ||
        scope.limit_value ||
        scope.offset_value
    end

    def null_relation?(scope)
      scope.respond_to?(:null_relation?) && scope.null_relation?
    end

    def unscoped_model
      @model.respond_to?(:unscoped) ? @model.unscoped : @model
    end

    def partition_clause(connection)
      @partition_by && "PARTITION BY #{connection.quote_column_name(@partition_by)}"
    end

    def quoted_table_name
      @model.connection.quote_table_name(@model.table_name)
    end

    def quoted_primary_key
      @model.connection.quote_column_name(@model.primary_key)
    end

    def qualified_primary_key
      "#{quoted_table_name}.#{quoted_primary_key}"
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
