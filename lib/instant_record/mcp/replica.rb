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

      ModelInfo = Struct.new(:name, :table, :columns, :primary_key, keyword_init: true)

      attr_reader :database_path

      def initialize(database_path:, models: nil)
        @database_path = File.expand_path(database_path.to_s)
        @explicit_models = normalize_model_list(models)
        @db = nil
        @model_index = nil
      end

      def reopen(new_path = @database_path)
        close
        @database_path = File.expand_path(new_path.to_s)
        @model_index = nil
        self
      end

      def refresh_schema!
        @model_index = nil
      end

      def close
        @db&.close unless @db&.closed?
        @db = nil
        @model_index = nil
      end

      def models
        started = monotonic_now
        list = resolved_models.values.map do |info|
          quoted = quote_ident(info.table)
          count = connection.get_first_value("SELECT COUNT(*) FROM #{quoted}").to_i
          pending =
            if info.columns.any? { |c| c[:name] == "sync_state" }
              connection.get_first_value("SELECT COUNT(*) FROM #{quoted} WHERE \"sync_state\" = ?", ["pending"]).to_i
            else
              0
            end
          {
            "name" => info.name,
            "table" => info.table,
            "primary_key" => info.primary_key,
            "count" => count,
            "pending_count" => pending,
            "columns" => info.columns.map { |col| stringify_hash(col) }
          }
        end
        { "models" => list, "elapsed_ms" => elapsed_ms(started) }
      end

      def query(model:, where: {}, order: nil, limit: DEFAULT_LIMIT, offset: 0, columns: nil)
        started = monotonic_now
        info = resolve_model!(model)
        valid_cols = info.columns.map { |c| c[:name] }

        selected = select_columns(columns, valid_cols)
        where_sql, binds = build_where(where, valid_cols)
        order_sql = build_order(order, valid_cols)
        clamped_limit = clamp_limit(limit)
        clamped_offset = [offset.to_i, 0].max

        table_sql = quote_ident(info.table)
        sql = "SELECT #{selected} FROM #{table_sql}#{where_sql}#{order_sql} LIMIT ? OFFSET ?"
        rows = nil
        total = nil
        connection.prepare("SELECT COUNT(*) FROM #{table_sql}#{where_sql}") do |counted|
          counted.bind_params(binds)
          rows = connection.execute(sql, binds + [clamped_limit, clamped_offset]).dup
          # Rows that do not fill their page are the last: they tell the total.
          last_page = rows.any? && rows.size < clamped_limit
          total = last_page ? clamped_offset + rows.size : counted.step.first.to_i
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
        pk = info.primary_key || "id"
        sql = "SELECT * FROM #{quote_ident(info.table)} WHERE #{quote_ident(pk)} = ? LIMIT 1"
        row = connection.get_first_row(sql, [bind_value(id)])

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
        tokens = text.split(/\s+/).reject(&:empty?)

        if tokens.empty?
          return { "query" => text, "count" => 0, "matches" => [], "elapsed_ms" => elapsed_ms(started) }
        end

        target_models =
          if models && !Array(models).empty?
            Array(models).map { |name| resolve_model!(name) }
          else
            resolved_models.values
          end

        requested_cols = columns ? Array(columns).map(&:to_s) : nil
        patterns = tokens.map { |token| "%#{escape_like(token.downcase)}%" }
        lowered_tokens = tokens.map(&:downcase)

        matches = []
        target_models.each do |info|
          break if matches.size >= clamped_limit

          searchable = searchable_columns(info, requested_cols)
          next if searchable.empty?

          remaining = clamped_limit - matches.size
          clauses = []
          binds = []
          # LIKE folds ASCII case itself.
          patterns.each do |pattern|
            per_col = searchable.map do |col|
              binds << pattern
              "CAST(#{quote_ident(col)} AS TEXT) LIKE ? ESCAPE '\\'"
            end
            clauses << "(#{per_col.join(' OR ')})"
          end

          order_clause =
            if info.columns.any? { |c| c[:name] == "updated_at" }
              " ORDER BY \"updated_at\" DESC"
            elsif info.columns.any? { |c| c[:name] == "created_at" }
              " ORDER BY \"created_at\" DESC"
            else
              ""
            end

          sql = "SELECT * FROM #{quote_ident(info.table)} WHERE #{clauses.join(' AND ')}#{order_clause} LIMIT ?"
          rows = connection.execute(sql, binds + [remaining])
          pk = info.primary_key || "id"

          rows.each do |row|
            matched_cols = searchable.select do |col|
              val = row[col]
              next false if val.nil?

              down = val.to_s.downcase
              lowered_tokens.any? { |tok| down.include?(tok) }
            end
            matches << {
              "model" => info.name,
              "table" => info.table,
              "id" => row[pk],
              "matched_columns" => matched_cols,
              "record" => row
            }
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
          raise Error, "Local SQLite replica does not exist yet: #{@database_path}" unless File.file?(@database_path)

          @db = SQLite3::Database.new(@database_path, readonly: true)
          @db.results_as_hash = true
          @db.busy_timeout = 5000
        end
        @db
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

        @model_index = index
      end

      def build_model_info(name, table)
        cols = connection.execute("PRAGMA table_info(#{quote_ident(table)})").map do |col|
          {
            name: col["name"].to_s,
            type: col["type"].to_s,
            notnull: col["notnull"].to_i == 1,
            primary_key: col["pk"].to_i > 0
          }
        end
        pk = cols.find { |c| c[:primary_key] }&.dig(:name) || "id"
        ModelInfo.new(name: name, table: table, columns: cols, primary_key: pk)
      end

      def resolve_model!(name)
        key = name.to_s.strip
        raise ArgumentError, "Model name is required" if key.empty?

        models_map = resolved_models
        return models_map[key] if models_map.key?(key)

        down = key.downcase
        found = models_map.values.find do |info|
          info.name.downcase == down || info.table.downcase == down || underscore(info.name) == down
        end
        return found if found

        available = models_map.keys.join(", ")
        raise ArgumentError, "Unknown synced model #{key.inspect}. Available models: #{available}"
      end

      def select_columns(columns, valid_cols)
        return "*" if columns.nil? || Array(columns).empty?

        Array(columns).map do |col|
          name = col.to_s
          validate_column!(name, valid_cols)
          quote_ident(name)
        end.join(", ")
      end

      def build_where(where, valid_cols)
        return ["", []] if where.nil? || (where.is_a?(Hash) && where.empty?)
        raise ArgumentError, "where must be an object/hash" unless where.is_a?(Hash)

        clauses = []
        binds = []

        where.each do |raw_col, condition|
          col = raw_col.to_s
          validate_column!(col, valid_cols)
          col_sql = quote_ident(col)

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
          validate_column!(col.to_s, valid_cols)
          direction = dir.nil? || dir.empty? ? "ASC" : dir.upcase
          unless direction == "ASC" || direction == "DESC"
            raise ArgumentError, "Invalid sort direction #{dir.inspect}; expected ASC or DESC"
          end

          "#{quote_ident(col)} #{direction}"
        end

        " ORDER BY #{parts.join(', ')}"
      end

      def searchable_columns(info, requested_cols)
        valid_cols = info.columns.map { |c| c[:name] }
        if requested_cols && !requested_cols.empty?
          requested_cols.each { |col| validate_column!(col, valid_cols) }
          return requested_cols
        end

        text_cols = info.columns.filter_map do |col|
          next if BOOKKEEPING_COLUMNS.include?(col[:name])

          type = col[:type].upcase
          next if type.include?("BLOB")

          if type.empty? || type.include?("CHAR") || type.include?("TEXT") || type.include?("CLOB") || type.include?("STRING")
            col[:name]
          end
        end

        text_cols.empty? ? valid_cols - BOOKKEEPING_COLUMNS : text_cols
      end

      def validate_column!(name, valid_cols)
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

      def stringify_hash(hash)
        hash.transform_keys(&:to_s)
      end

      def clamp_limit(limit)
        value = limit.nil? ? DEFAULT_LIMIT : limit.to_i
        value = DEFAULT_LIMIT if value <= 0
        [value, MAX_LIMIT].min
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
