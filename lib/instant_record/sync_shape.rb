module InstantRecord
  # Declarative sync shape on a Syncable model (`sync_shape`): defines the root
  # relation for windowed bootstrap and keyset history paging, optional related
  # rows that ride along with each page of roots, optional server-side search
  # widening, optional single-root lookup, and optional background history-fill.
  class SyncShape
    attr_reader :model, :limit, :min_limit, :max_limit, :fill_page_size, :fill_budget_bytes

    # Whether a keyset page must also say `created_at <= before`, which its own
    # condition already means. SQLite takes that range from the condition's OR,
    # but only when both its times are the same literal: as two binds of a
    # prepared statement they may differ. PostgreSQL never takes it. Without
    # it, every newer row is read before the page's first.
    def self.needs_range?(model)
      model.connection_pool.with_connection do |connection|
        connection.adapter_name != "SQLite" || connection.prepared_statements
      end
    end

    def initialize(model, limit: 50, min_limit: 1, max_limit: 200, roots: nil, include: nil,
                   search: nil, lookup: nil, background_fill: false, fill_page_size: nil, fill_budget_bytes: nil)
      unless limit.is_a?(Integer) && limit.positive?
        raise ArgumentError, "sync_shape limit must be a positive integer (got #{limit.inspect})"
      end
      unless min_limit.is_a?(Integer) && min_limit.positive?
        raise ArgumentError, "sync_shape min_limit must be a positive integer (got #{min_limit.inspect})"
      end
      unless max_limit.is_a?(Integer) && max_limit >= limit && max_limit >= min_limit
        raise ArgumentError, "sync_shape max_limit must be an integer >= limit and min_limit (got #{max_limit.inspect})"
      end
      if !fill_page_size.nil? && !(fill_page_size.is_a?(Integer) && fill_page_size.positive?)
        raise ArgumentError, "sync_shape fill_page_size must be a positive integer (got #{fill_page_size.inspect})"
      end
      if !fill_budget_bytes.nil? && !(fill_budget_bytes.is_a?(Integer) && fill_budget_bytes.positive?)
        raise ArgumentError, "sync_shape fill_budget_bytes must be a positive integer (got #{fill_budget_bytes.inspect})"
      end

      @model = model
      @limit = limit
      @min_limit = min_limit
      @max_limit = max_limit
      @roots = roots
      @include = include
      @search = search
      @lookup = lookup
      @background_fill = !!background_fill
      @fill_page_size = fill_page_size || max_limit
      @fill_budget_bytes = fill_budget_bytes
    end

    def searchable? = !@search.nil?
    def background_fill? = @background_fill

    # Base relation for root rows, narrowed by the caller's visibility/partition scope.
    def root_scope(base)
      @roots ? base.instance_exec(&@roots) : base
    end

    # First-sync bootstrap page: newest `limit` root rows plus any related rows.
    def bootstrap_records(base)
      pk = @model.primary_key
      roots = root_scope(base).order(created_at: :desc, pk => :desc).limit(@limit).to_a
      expand(base, roots)
    end

    # Keyset page below (before_at, before_id) — or from newest when omitted —
    # optionally narrowed by `search`. Returns { records:, has_more:, next_before: }.
    def page(base, before_at: nil, before_id: nil, limit: nil, search: nil)
      pk = @model.primary_key
      size = (limit ? limit.to_i : @limit).clamp(@min_limit, @max_limit)
      relation = root_scope(base)
      if search.present?
        raise ArgumentError, "#{@model.name} sync_shape does not support search" unless @search

        relation = relation.instance_exec(search, &@search)
      end
      if before_at && before_id.present?
        created_col, pk_col = @model.connection_pool.with_connection do |connection|
          table = connection.quote_table_name(@model.table_name)
          [
            "#{table}.#{connection.quote_column_name('created_at')}",
            "#{table}.#{connection.quote_column_name(pk)}"
          ]
        end
        # Before the OR: without an index, a row above the page fails at once.
        relation = relation.where("#{created_col} <= ?", before_at) if self.class.needs_range?(@model)
        relation = relation.where("#{created_col} < :at OR (#{created_col} = :at AND #{pk_col} < :id)", at: before_at, id: before_id)
      end

      fetched = relation.order(created_at: :desc, pk => :desc).limit(size + 1).to_a
      has_more = fetched.size > size
      roots = fetched.first(size)
      last = roots.last
      next_before =
        if last&.created_at
          {
            created_at: last.created_at.utc.iso8601(InstantRecord::TIME_PRECISION),
            id: last.id
          }
        end
      { records: expand(base, roots), has_more: has_more, next_before: next_before }
    end

    # Single-root lookup (e.g. deep link to a record outside the bootstrap window),
    # expanded with its related rows.
    def lookup(base, id)
      relation = @lookup ? base.instance_exec(id, &@lookup) : base.where(@model.primary_key => id)
      expand(base, relation.to_a)
    end

    # Descriptor sent in bootstrap JSON so the browser/native worker knows how
    # to background-fill this model without hardcoding model names or columns.
    def fill_descriptor(partition: nil)
      return nil unless background_fill?

      descriptor = { type: @model.name, page_size: @fill_page_size }
      descriptor[:partition] = partition if partition
      descriptor[:budget_bytes] = @fill_budget_bytes if @fill_budget_bytes
      descriptor
    end

    private

    def expand(base, roots)
      return roots if roots.empty? || @include.nil?

      related = base.instance_exec(roots, &@include).to_a
      roots + related
    end
  end
end
