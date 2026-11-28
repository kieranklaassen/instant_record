require "json"
require "sqlite3"

module InstantRecord
  module Mcp
    # Sub-millisecond (<1ms) read-only query and search interface over the
    # native host's local SQLite replica.
    #
    # Never mutates SQLite directly — all writes go through the compiled native
    # host so validations and outbox mutation recording run atomically.
    class Replica
      INTERNAL_TABLE_PREFIXES = %w[sqlite_ instant_record_].freeze
      INTERNAL_TABLES = %w[ar_internal_metadata schema_migrations].freeze
      BOOKKEEPING_COLUMNS = %w[server_version sync_state].freeze
      DEFAULT_LIMIT = 50
      MAX_LIMIT = 500
      OPERATORS = %w[eq ne gt gte lt lte like in is_null not_null].freeze

      MAX_CACHED_STATEMENTS = 64

      ModelInfo = Struct.new(
        :name,
        :table,
        :columns,
        :primary_key,
        :quoted_table,
        :quoted_pk,
        :has_sync_state,
        :valid_col_names,
        :valid_col_set,
        :quoted_cols,
        :stringified_columns,
        :default_searchable_columns,
        :default_search_sql_1_plain,
        :default_search_sql_2_plain,
        :search_order_clause,
        :find_sql,
        :models_count_sql,
        keyword_init: true
      )

      CachedStatement = Struct.new(:stmt, :columns, :reprepares, :row_template, :col_pos)

      attr_reader :database_path

      def initialize(database_path:, models: nil)
        @database_path = File.expand_path(database_path.to_s)
        @explicit_models = normalize_model_list(models)
        @db = nil
        @model_index = nil
        @model_lookup = nil
        @models_summary_sql = nil
        @stmt_cache = {}
      end

      def reopen(new_path = @database_path)
        close
        @database_path = File.expand_path(new_path.to_s)
        self
      end

      def refresh_schema!
        clear_statement_cache!
        @model_index = nil
        @model_lookup = nil
        @models_summary_sql = nil
      end

      def close
        clear_statement_cache!
        @db&.close unless @db&.closed?
        @db = nil
        @model_index = nil
        @model_lookup = nil
        @models_summary_sql = nil
      end

      def models
        started = monotonic_now
        models_list = resolved_models.values
        if models_list.empty?
          return { "models" => [], "elapsed_ms" => elapsed_ms(started) }
        end

        list = Array.new(models_list.size)
        if @models_summary_sql
          with_statement(@models_summary_sql) do |entry|
            stmt = entry.stmt
            i = 0
            while (row = stmt.step) && !stmt.done?
              list[i] = build_model_summary(models_list[i], row[0].to_i, row[1].to_i)
              i += 1
            end
          end
        else
          models_list.each_with_index do |info, i|
            count = 0
            pending = 0
            with_statement(info.models_count_sql) do |entry|
              row = entry.stmt.step
              unless entry.stmt.done?
                count = row[0].to_i
                pending = row[1].to_i
              end
            end
            list[i] = build_model_summary(info, count, pending)
          end
        end

        { "models" => list, "elapsed_ms" => elapsed_ms(started) }
      end

      def query(model:, where: {}, order: nil, limit: DEFAULT_LIMIT, offset: 0, columns: nil)
        started = monotonic_now
        info = resolve_model!(model)

        selected = select_columns(columns, info)
        where_sql, binds = build_where(where, info)
        order_sql = build_order(order, info)
        clamped_limit = clamp_limit(limit)
        clamped_offset = offset.to_i
        clamped_offset = 0 if clamped_offset < 0

        table_sql = info.quoted_table
        sql = "SELECT #{selected} FROM #{table_sql}#{where_sql}#{order_sql} LIMIT ? OFFSET ?"
        rows = fetch_hash_rows_paginated(sql, binds, clamped_limit, clamped_offset)

        # Rows that do not fill their page are the last: they tell the total.
        if !rows.empty? && rows.size < clamped_limit
          total = clamped_offset + rows.size
        else
          count_sql = "SELECT COUNT(*) FROM #{table_sql}#{where_sql}"
          total = fetch_first_int(count_sql, binds)
        end

        {
          "model" => info.name,
          "table" => info.table,
          "count" => rows.size,
          "total" => total,
          "limit" => clamped_limit,
          "offset" => clamped_offset,
          "rows" => rows,
          "elapsed_ms" => elapsed_ms(started)
        }
      end

      def find(model:, id:)
        started = monotonic_now
        info = resolve_model!(model)
        row = fetch_first_hash_row(info.find_sql, bind_value(id))

        {
          "model" => info.name,
          "table" => info.table,
          "id" => id,
          "record" => row,
          "elapsed_ms" => elapsed_ms(started)
        }
      end

      def search(query:, models: nil, columns: nil, limit: DEFAULT_LIMIT)
        started = monotonic_now
        text = query.to_s.strip
        clamped_limit = clamp_limit(limit)
        tokens = text.split

        if tokens.empty?
          return { "query" => text, "count" => 0, "matches" => [], "elapsed_ms" => elapsed_ms(started) }
        end

        target_models =
          if models
            model_list = models.is_a?(Array) ? models : Array(models)
            model_list.empty? ? resolved_models.values : model_list.map { |name| resolve_model!(name) }
          else
            resolved_models.values
          end

        requested_cols =
          if columns
            col_list = columns.is_a?(Array) ? columns : Array(columns)
            col_list.empty? ? nil : col_list.map(&:to_s)
          end

        unique_tokens = tokens.map(&:downcase)
        unique_tokens.uniq! if unique_tokens.size > 1
        sql_tokens = unique_tokens.size > 1 ? unique_tokens.sort_by { |t| -t.bytesize } : unique_tokens

        patterns = Array.new(sql_tokens.size)
        needs_escape = Array.new(sql_tokens.size)
        sql_tokens.each_with_index do |tok, idx|
          if tok.include?("%") || tok.include?("_") || tok.include?("\\")
            patterns[idx] = "%#{escape_like(tok)}%"
            needs_escape[idx] = true
          else
            patterns[idx] = "%#{tok}%"
            needs_escape[idx] = false
          end
        end

        ascii_matcher =
          if unique_tokens.all?(&:ascii_only?)
            if unique_tokens.size == 1
              Regexp.new(Regexp.escape(unique_tokens[0]), Regexp::IGNORECASE)
            else
              Regexp.new(unique_tokens.map { |t| Regexp.escape(t) }.join("|"), Regexp::IGNORECASE)
            end
          end

        matches = []
        pattern_count = patterns.size
        default_cols = requested_cols.nil?

        target_models.each do |info|
          break if matches.size >= clamped_limit

          searchable = default_cols ? info.default_searchable_columns : searchable_columns(info, requested_cols)
          next if searchable.empty?

          remaining = clamped_limit - matches.size
          sql = build_search_sql(info, searchable, default_cols, needs_escape)
          pk = info.primary_key
          searchable_size = searchable.size

          with_statement(sql) do |entry|
            stmt = entry.stmt
            p_idx = 0
            while p_idx < pattern_count
              stmt.bind_param(p_idx + 1, patterns[p_idx])
              p_idx += 1
            end
            stmt.bind_param(pattern_count + 1, remaining)

            cols = nil
            template = nil
            col_count = 0
            pk_idx = nil
            searchable_indices = nil

            while (raw = stmt.step) && !stmt.done?
              if cols.nil?
                cols = statement_columns(entry, raw.size)
                template = entry.row_template
                col_count = cols.size
                col_pos = entry.col_pos
                pk_idx = col_pos[pk]
                searchable_indices = Array.new(searchable_size) { |j| col_pos[searchable[j]] }
              end

              record = build_row_hash(template, cols, col_count, raw)

              matched_cols = []
              j = 0
              while j < searchable_size
                idx = searchable_indices[j]
                val = idx ? raw[idx] : nil
                unless val.nil?
                  matched =
                    if ascii_matcher
                      if val.is_a?(String)
                        if val.ascii_only?
                          ascii_matcher.match?(val)
                        else
                          down = val.downcase
                          unique_tokens.any? { |tok| down.include?(tok) }
                        end
                      else
                        ascii_matcher.match?(val.to_s)
                      end
                    else
                      down = val.to_s.downcase
                      unique_tokens.any? { |tok| down.include?(tok) }
                    end
                  matched_cols << searchable[j] if matched
                end
                j += 1
              end

              matches << {
                "model" => info.name,
                "table" => info.table,
                "id" => pk_idx ? raw[pk_idx] : nil,
                "matched_columns" => matched_cols,
                "record" => record
              }
            end
          end
        end

        {
          "query" => text,
          "count" => matches.size,
          "matches" => matches,
          "elapsed_ms" => elapsed_ms(started)
        }
      end

      def outbox(limit: 100)
        started = monotonic_now
        clamped = clamp_limit(limit)
        unless table_exists?("instant_record_outbox")
          return { "count" => 0, "mutations" => [], "elapsed_ms" => elapsed_ms(started) }
        end

        total = connection.get_first_value("SELECT COUNT(*) FROM \"instant_record_outbox\"").to_i
        rows = connection.execute(
          "SELECT * FROM \"instant_record_outbox\" ORDER BY \"created_at\" ASC, \"id\" ASC LIMIT ?",
          [clamped]
        ).map do |row|
          if row["changes_payload"].is_a?(String) && !row["changes_payload"].empty?
            row["changes"] = JSON.parse(row["changes_payload"]) rescue row["changes_payload"]
          end
          row
        end

        { "count" => total, "mutations" => rows, "elapsed_ms" => elapsed_ms(started) }
      end

      def metadata
        return {} unless table_exists?("instant_record_sync_metadata")

        connection.execute("SELECT \"key\", \"value\" FROM \"instant_record_sync_metadata\"").each_with_object({}) do |row, acc|
          acc[row["key"].to_s] = row["value"]
        end
      end

      private

      def connection
        if @db.nil? || @db.closed?
          clear_statement_cache!
          raise Error, "Local SQLite replica does not exist yet: #{@database_path}" unless File.file?(@database_path)

          @db = SQLite3::Database.new(@database_path, readonly: true)
          @db.results_as_hash = true
          @db.busy_timeout = 5000
        end
        @db
      end

      def clear_statement_cache!
        return if @stmt_cache.nil? || @stmt_cache.empty?

        @stmt_cache.each_value do |entry|
          stmt = entry.stmt
          stmt.close unless stmt.closed?
        end
        @stmt_cache.clear
      end

      def with_statement(sql)
        entry = @stmt_cache[sql]
        if entry.nil? || entry.stmt.closed?
          if @stmt_cache.size >= MAX_CACHED_STATEMENTS
            _, evicted = @stmt_cache.shift
            evicted.stmt.close unless evicted.stmt.closed?
          end
          stmt = connection.prepare(sql)
          entry = CachedStatement.new(stmt, nil, nil, nil, nil)
          @stmt_cache[sql] = entry
        end

        yield entry
      rescue SQLite3::Exception
        if entry
          @stmt_cache.delete(sql)
          entry.stmt.close unless entry.stmt.closed?
        end
        raise
      ensure
        if entry && !entry.stmt.closed?
          entry.stmt.reset!
        end
      end

      def statement_columns(entry, row_size)
        stmt = entry.stmt
        reprepares = stmt.stat(:reprepares)
        if entry.columns.nil? || reprepares != entry.reprepares || row_size != entry.columns.size
          count = stmt.column_count
          cols = Array.new(count) { |i| stmt.column_name(i).freeze }.freeze
          col_pos = {}
          i = 0
          while i < count
            col_pos[cols[i]] = i
            i += 1
          end
          entry.columns = cols
          entry.reprepares = reprepares
          entry.col_pos = col_pos.freeze
          entry.row_template =
            if col_pos.size == count
              tpl = {}
              j = 0
              while j < count
                tpl[cols[j]] = nil
                j += 1
              end
              tpl.freeze
            end
        end
        entry.columns
      end

      def build_row_hash(template, cols, col_count, raw)
        if template
          i = 0
          template.transform_values do
            val = raw[i]
            i += 1
            val
          end
        else
          hash = {}
          i = 0
          while i < col_count
            hash[cols[i]] = raw[i]
            i += 1
          end
          hash
        end
      end

      def bind_all_simple?(binds)
        i = 0
        len = binds.size
        while i < len
          v = binds[i]
          return false if v.is_a?(Hash) || v.is_a?(Array)

          i += 1
        end
        true
      end

      def fetch_first_hash_row(sql, single_bind)
        with_statement(sql) do |entry|
          stmt = entry.stmt
          if single_bind.is_a?(Hash) || single_bind.is_a?(Array)
            stmt.clear_bindings!
            stmt.bind_params([single_bind])
          else
            stmt.bind_param(1, single_bind)
          end

          raw = stmt.step
          return nil if stmt.done?

          cols = statement_columns(entry, raw.size)
          build_row_hash(entry.row_template, cols, cols.size, raw)
        end
      end

      def fetch_hash_rows_paginated(sql, binds, limit, offset)
        with_statement(sql) do |entry|
          stmt = entry.stmt
          if !binds.empty? && !bind_all_simple?(binds)
            stmt.clear_bindings!
            stmt.bind_params(binds + [limit, offset])
          else
            i = 0
            len = binds.size
            while i < len
              stmt.bind_param(i + 1, binds[i])
              i += 1
            end
            stmt.bind_param(len + 1, limit)
            stmt.bind_param(len + 2, offset)
          end

          rows = []
          cols = nil
          template = nil
          col_count = 0
          while (raw = stmt.step) && !stmt.done?
            if cols.nil?
              cols = statement_columns(entry, raw.size)
              template = entry.row_template
              col_count = cols.size
            end
            rows << build_row_hash(template, cols, col_count, raw)
          end
          rows
        end
      end

      def fetch_first_int(sql, binds)
        with_statement(sql) do |entry|
          stmt = entry.stmt
          if !binds.empty? && !bind_all_simple?(binds)
            stmt.clear_bindings!
            stmt.bind_params(binds)
          else
            i = 0
            len = binds.size
            while i < len
              stmt.bind_param(i + 1, binds[i])
              i += 1
            end
          end

          raw = stmt.step
          stmt.done? ? 0 : raw[0].to_i
        end
      end

      def build_search_sql(info, searchable, is_default, needs_escape)
        n = needs_escape.size
        if is_default
          if n == 1 && !needs_escape[0]
            return info.default_search_sql_1_plain
          elsif n == 2 && !needs_escape[0] && !needs_escape[1]
            return info.default_search_sql_2_plain
          end
        end

        quoted_cols = info.quoted_cols
        clauses = Array.new(n) do |i|
          param = "?#{i + 1}"
          suffix = needs_escape[i] ? " LIKE #{param} ESCAPE '\\'" : " LIKE #{param}"
          "(#{searchable.map { |col| "#{quoted_cols[col] || quote_ident(col)}#{suffix}" }.join(' OR ')})"
        end

        "SELECT * FROM #{info.quoted_table} WHERE #{clauses.join(' AND ')}#{info.search_order_clause} LIMIT ?#{n + 1}"
      end

      def table_exists?(name)
        !connection.get_first_value(
          "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
          [name.to_s]
        ).nil?
      end

      def all_user_tables
        connection.execute("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").filter_map do |row|
          name = row["name"].to_s
          next if INTERNAL_TABLES.include?(name)
          next if INTERNAL_TABLE_PREFIXES.any? { |prefix| name.start_with?(prefix) }

          name
        end
      end

      def resolved_models
        return @model_index if @model_index

        tables = all_user_tables
        compiled = metadata["compiled_models"].to_s.split(",").map(&:strip).reject(&:empty?)
        declared = @explicit_models && !@explicit_models.empty? ? @explicit_models : compiled

        index = {}
        if declared.any?
          declared.each do |model_name|
            table = match_table_for_model(model_name, tables)
            next unless table

            index[model_name] = build_model_info(model_name, table)
          end
        end

        if index.empty?
          tables.each do |table|
            model_name = classify_table(table)
            index[model_name] = build_model_info(model_name, table)
          end
        end

        lookup = {}
        index.each_value do |info|
          lookup[info.name.downcase] ||= info
          lookup[info.table.downcase] ||= info
          lookup[underscore(info.name)] ||= info
        end

        @model_lookup = lookup
        @models_summary_sql =
          if !index.empty? && index.size <= 100
            index.values.map(&:models_count_sql).join(" UNION ALL ").freeze
          end
        @model_index = index
      end

      def build_model_info(name, table)
        quoted_table = quote_ident(table).freeze
        cols = connection.execute("PRAGMA table_info(#{quoted_table})").map do |col|
          {
            name: col["name"].to_s.freeze,
            type: col["type"].to_s.freeze,
            notnull: col["notnull"].to_i == 1,
            primary_key: col["pk"].to_i > 0
          }
        end
        pk = (cols.find { |c| c[:primary_key] }&.dig(:name) || "id").freeze
        quoted_pk = quote_ident(pk).freeze
        valid_col_names = cols.map { |c| c[:name] }.freeze
        valid_col_set = valid_col_names.each_with_object({}) { |col_name, acc| acc[col_name] = true }.freeze
        quoted_cols = valid_col_names.each_with_object({}) { |col_name, acc| acc[col_name] = quote_ident(col_name).freeze }.freeze
        has_sync_state = valid_col_set.key?("sync_state")
        stringified_columns = cols.map do |col|
          {
            "name" => col[:name],
            "type" => col[:type],
            "notnull" => col[:notnull],
            "primary_key" => col[:primary_key]
          }.freeze
        end.freeze

        text_cols = cols.filter_map do |col|
          next if BOOKKEEPING_COLUMNS.include?(col[:name])

          type = col[:type].upcase
          next if type.include?("BLOB")

          if type.empty? || type.include?("CHAR") || type.include?("TEXT") || type.include?("CLOB") || type.include?("STRING")
            col[:name]
          end
        end
        default_searchable = (text_cols.empty? ? valid_col_names - BOOKKEEPING_COLUMNS : text_cols).freeze
        search_order_clause =
          if valid_col_set.key?("updated_at")
            ' ORDER BY "updated_at" DESC'
          elsif valid_col_set.key?("created_at")
            ' ORDER BY "created_at" DESC'
          else
            ""
          end

        default_search_sql_1_plain = nil
        default_search_sql_2_plain = nil
        unless default_searchable.empty?
          c1 = "(#{default_searchable.map { |col| "#{quoted_cols[col]} LIKE ?1" }.join(' OR ')})"
          c2 = "(#{default_searchable.map { |col| "#{quoted_cols[col]} LIKE ?2" }.join(' OR ')})"
          default_search_sql_1_plain = "SELECT * FROM #{quoted_table} WHERE #{c1}#{search_order_clause} LIMIT ?2".freeze
          default_search_sql_2_plain = "SELECT * FROM #{quoted_table} WHERE #{c1} AND #{c2}#{search_order_clause} LIMIT ?3".freeze
        end

        find_sql = "SELECT * FROM #{quoted_table} WHERE #{quoted_pk} = ? LIMIT 1".freeze
        models_count_sql =
          if has_sync_state
            "SELECT COUNT(*), COUNT(*) FILTER (WHERE \"sync_state\" = 'pending') FROM #{quoted_table}".freeze
          else
            "SELECT COUNT(*), 0 FROM #{quoted_table}".freeze
          end

        ModelInfo.new(
          name: name.freeze,
          table: table.freeze,
          columns: cols,
          primary_key: pk,
          quoted_table: quoted_table,
          quoted_pk: quoted_pk,
          has_sync_state: has_sync_state,
          valid_col_names: valid_col_names,
          valid_col_set: valid_col_set,
          quoted_cols: quoted_cols,
          stringified_columns: stringified_columns,
          default_searchable_columns: default_searchable,
          default_search_sql_1_plain: default_search_sql_1_plain,
          default_search_sql_2_plain: default_search_sql_2_plain,
          search_order_clause: search_order_clause,
          find_sql: find_sql,
          models_count_sql: models_count_sql
        )
      end

      def resolve_model!(name)
        models_map = resolved_models
        if name.is_a?(String)
          exact = models_map[name]
          return exact if exact
        end

        key = name.to_s.strip
        raise ArgumentError, "Model name is required" if key.empty?

        found = models_map[key] || @model_lookup[key.downcase]
        return found if found

        available = models_map.keys.join(", ")
        raise ArgumentError, "Unknown synced model #{key.inspect}. Available models: #{available}"
      end

      def select_columns(columns, valid_cols)
        return "*" if columns.nil?

        list = columns.is_a?(Array) ? columns : Array(columns)
        return "*" if list.empty?

        quoted_map = valid_cols.is_a?(ModelInfo) ? valid_cols.quoted_cols : nil
        list.map do |col|
          name = col.is_a?(String) ? col : col.to_s
          validate_column!(name, valid_cols)
          (quoted_map && quoted_map[name]) || quote_ident(name)
        end.join(", ")
      end

      def build_where(where, valid_cols)
        return ["", []] if where.nil? || (where.is_a?(Hash) && where.empty?)
        raise ArgumentError, "where must be an object/hash" unless where.is_a?(Hash)

        quoted_map = valid_cols.is_a?(ModelInfo) ? valid_cols.quoted_cols : nil

        if where.size == 1
          raw_col, condition = where.first
          col = raw_col.is_a?(String) ? raw_col : raw_col.to_s
          validate_column!(col, valid_cols)
          col_sql = (quoted_map && quoted_map[col]) || quote_ident(col)
          case condition
          when nil
            return [" WHERE #{col_sql} IS NULL", []]
          when Array
            binds = []
            return [" WHERE #{in_clause(col_sql, condition, binds)}", binds]
          when Hash
            return ["", []] if condition.empty?
            if condition.size == 1
              op, value = condition.first
              binds = []
              return [" WHERE #{operator_clause(col, col_sql, op.to_s, value, binds)}", binds]
            end
          else
            return [" WHERE #{col_sql} = ?", [bind_value(condition)]]
          end
        end

        clauses = []
        binds = []

        where.each do |raw_col, condition|
          col = raw_col.is_a?(String) ? raw_col : raw_col.to_s
          validate_column!(col, valid_cols)
          col_sql = (quoted_map && quoted_map[col]) || quote_ident(col)

          case condition
          when nil
            clauses << "#{col_sql} IS NULL"
          when Array
            clauses << in_clause(col_sql, condition, binds)
          when Hash
            condition.each { |op, value| clauses << operator_clause(col, col_sql, op.to_s, value, binds) }
          else
            clauses << bound("#{col_sql} = ?", condition, binds)
          end
        end

        return ["", []] if clauses.empty?

        [" WHERE #{clauses.join(' AND ')}", binds]
      end

      def operator_clause(col, col_sql, op, value, binds)
        case op
        when "eq" then value.nil? ? "#{col_sql} IS NULL" : bound("#{col_sql} = ?", value, binds)
        when "ne" then value.nil? ? "#{col_sql} IS NOT NULL" : bound("#{col_sql} != ?", value, binds)
        when "gt" then bound("#{col_sql} > ?", value, binds)
        when "gte" then bound("#{col_sql} >= ?", value, binds)
        when "lt" then bound("#{col_sql} < ?", value, binds)
        when "lte" then bound("#{col_sql} <= ?", value, binds)
        when "like"
          bound("CAST(#{col_sql} AS TEXT) LIKE ? ESCAPE '\\'", "%#{escape_like(value.to_s.downcase)}%", binds)
        when "in" then in_clause(col_sql, Array(value), binds)
        when "is_null" then value ? "#{col_sql} IS NULL" : "#{col_sql} IS NOT NULL"
        when "not_null" then value ? "#{col_sql} IS NOT NULL" : "#{col_sql} IS NULL"
        else
          raise ArgumentError, "Unsupported filter operator #{op.inspect} for column #{col}. Allowed: #{OPERATORS.join(', ')}"
        end
      end

      def in_clause(col_sql, list, binds)
        return "1 = 0" if list.empty?

        placeholders = list.map { "?" }.join(", ")
        list.each { |item| binds << bind_value(item) }
        "#{col_sql} IN (#{placeholders})"
      end

      def bound(sql, value, binds)
        binds << bind_value(value)
        sql
      end

      def build_order(order, valid_cols)
        return "" if order.nil?

        quoted_map = valid_cols.is_a?(ModelInfo) ? valid_cols.quoted_cols : nil

        if order.is_a?(String) && !order.include?(",")
          trimmed = order.strip
          return "" if trimmed.empty?

          col, dir = trimmed.split(/\s+/, 2)
          col_name = col.to_s
          validate_column!(col_name, valid_cols)
          direction =
            if dir.nil? || dir.empty?
              "ASC"
            elsif dir.casecmp?("ASC")
              "ASC"
            elsif dir.casecmp?("DESC")
              "DESC"
            else
              raise ArgumentError, "Invalid sort direction #{dir.inspect}; expected ASC or DESC"
            end

          col_sql = (quoted_map && quoted_map[col_name]) || quote_ident(col_name)
          return " ORDER BY #{col_sql} #{direction}"
        end

        specs =
          case order
          when String
            order.split(",").map(&:strip).reject(&:empty?)
          when Array
            order.map(&:to_s).map(&:strip).reject(&:empty?)
          when Hash
            order.map { |col, dir| "#{col} #{dir}" }
          else
            raise ArgumentError, "Invalid order specification: #{order.inspect}"
          end

        return "" if specs.empty?

        parts = specs.map do |spec|
          col, dir = spec.split(/\s+/, 2)
          col_name = col.to_s
          validate_column!(col_name, valid_cols)
          direction = dir.nil? || dir.empty? ? "ASC" : dir.upcase
          unless direction == "ASC" || direction == "DESC"
            raise ArgumentError, "Invalid sort direction #{dir.inspect}; expected ASC or DESC"
          end

          col_sql = (quoted_map && quoted_map[col_name]) || quote_ident(col_name)
          "#{col_sql} #{direction}"
        end

        " ORDER BY #{parts.join(', ')}"
      end

      def searchable_columns(info, requested_cols)
        if requested_cols && !requested_cols.empty?
          requested_cols.each { |col| validate_column!(col, info) }
          return requested_cols
        end

        info.default_searchable_columns
      end

      def validate_column!(name, valid_cols)
        if valid_cols.is_a?(ModelInfo)
          return if valid_cols.valid_col_set.key?(name)

          raise ArgumentError, "Unknown column #{name.inspect}. Available columns: #{valid_cols.valid_col_names.join(', ')}"
        end

        return if valid_cols.include?(name)

        raise ArgumentError, "Unknown column #{name.inspect}. Available columns: #{valid_cols.join(', ')}"
      end

      def quote_ident(ident)
        %("#{ident.to_s.gsub('"', '""')}")
      end

      def escape_like(str)
        str.gsub(/[\\%_]/) { |ch| "\\#{ch}" }
      end

      def bind_value(value)
        case value
        when true then 1
        when false then 0
        else value
        end
      end

      def build_model_summary(info, count, pending)
        {
          "name" => info.name,
          "table" => info.table,
          "primary_key" => info.primary_key,
          "count" => count,
          "pending_count" => pending,
          "columns" => info.stringified_columns.map(&:dup)
        }
      end

      def clamp_limit(limit)
        value = limit.nil? ? DEFAULT_LIMIT : limit.to_i
        value = DEFAULT_LIMIT if value <= 0
        value > MAX_LIMIT ? MAX_LIMIT : value
      end

      def normalize_model_list(models)
        return nil if models.nil?

        Array(models).map(&:to_s).map(&:strip).reject(&:empty?)
      end

      def match_table_for_model(model_name, tables)
        candidate = tableize(model_name)
        return candidate if tables.include?(candidate)

        short = tableize(model_name.split("::").last)
        return short if tables.include?(short)

        tables.find { |t| t.downcase == candidate.downcase || t.downcase == short.downcase }
      end

      def tableize(model_name)
        if defined?(ActiveSupport::Inflector)
          ActiveSupport::Inflector.tableize(model_name)
        else
          pluralize(underscore(model_name.tr("::", "_")))
        end
      end

      def classify_table(table)
        if defined?(ActiveSupport::Inflector)
          ActiveSupport::Inflector.classify(table)
        else
          singular = table.sub(/ies\z/, "y").sub(/(?:es|s)\z/, "")
          singular.split("_").map(&:capitalize).join
        end
      end

      def underscore(name)
        name.to_s
          .gsub("::", "/")
          .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
          .gsub(/([a-z\d])([A-Z])/, '\1_\2')
          .tr("-", "_")
          .downcase
      end

      def pluralize(word)
        return "#{word[0..-2]}ies" if word.end_with?("y") && !word.end_with?("ay", "ey", "iy", "oy", "uy")
        return "#{word}es" if word.end_with?("s", "x", "z", "ch", "sh")

        "#{word}s"
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def elapsed_ms(started)
        ((monotonic_now - started) * 1000.0).round(3)
      end
    end
  end
end
