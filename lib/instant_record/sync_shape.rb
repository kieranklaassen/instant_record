module InstantRecord
  # Declarative sync shape on a Syncable model (`sync_shape`): defines the root
  # relation for windowed bootstrap and keyset history paging, optional related
  # rows that ride along with each page of roots, optional server-side search
  # widening, optional single-root lookup, and optional background history-fill.
  class SyncShape
    attr_reader :model, :limit, :min_limit, :max_limit, :fill_page_size, :fill_budget_bytes

    # Whether a keyset page must also say `created_at <= before`, which its own
    # condition already means. SQLite takes that range from the condition's OR.
    # PostgreSQL does not, and reads every newer row before the page's first.
    def self.needs_range?(model)
      model.connection_pool.with_connection { |connection| connection.adapter_name != "SQLite" }
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

      @model = model
      @limit = limit
      @min_limit = min_limit
      @max_limit = max_limit
      @roots = roots
      @include = include
      @search = search
      @lookup = lookup
      @background_fill = !!background_fill
      @fill_page_size = (fill_page_size || max_limit).to_i
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
        relation = relation.where("created_at < :at OR (created_at = :at AND #{pk} < :id)", at: before_at, id: before_id)
        relation = relation.where("created_at <= ?", before_at) if self.class.needs_range?(@model)
      end

      fetched = relation.order(created_at: :desc, pk => :desc).limit(size + 1).to_a
      has_more = fetched.size > size
      roots = fetched.first(size)
      last = roots.last
      next_before = last && {
        created_at: last.created_at.utc.iso8601(InstantRecord::TIME_PRECISION),
        id: last.id
      }
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
