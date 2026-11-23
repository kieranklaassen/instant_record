require "json"

module InstantRecord
  # Lightweight table and partition read tracker for handle_request and render.
  #
  # Captures SELECT queries executed within a tracked block (via
  # ActiveSupport::Notifications in CRuby, or direct record_sql calls from the
  # compiled SQLite adapter), extracting referenced tables and sound outer-WHERE
  # partition equality constraints.
  #
  # Soundness rule: a table is only narrowed to partition values when EVERY query
  # touching that table in the tracked block constrains that partition column via
  # top-level AND-ed `=` or `IN` predicates (with no top-level `OR`). Any query
  # that reads a table without constraining a column drops that column from the
  # table's partition filter, safely falling back to whole-table invalidation.
  module ReadTracker
    INTERNAL_TABLES = %w[
      sqlite_master
      sqlite_schema
      sqlite_temp_master
      sqlite_temp_schema
      schema_migrations
      ar_internal_metadata
      instant_record_outbox
      instant_record_sync_metadata
      instant_record_changes
      instant_record_applied_mutations
    ].freeze

    SQL_KEYWORDS = %w[
      where join inner left right full cross outer on group order limit offset
      having union intersect except set values into as
    ].freeze

    class << self
      def tracking?
        !!@tracking
      end

      def last_reads
        @last_reads
      end

      # Run a block while tracking table/partition reads. Returns the finalized
      # reads snapshot hash (and stores it in `last_reads`).
      def track(&block)
        _value, reads = capture(&block)
        reads
      end

      # Run a block while tracking table/partition reads. Returns [block_value, reads].
      def capture(&block)
        previous_tracking = @tracking
        previous_frame = @frame
        @tracking = true
        @frame = {}

        value =
          if defined?(ActiveSupport::Notifications) && ActiveSupport::Notifications.respond_to?(:subscribed)
            callback = lambda do |_name, _start, _finish, _id, payload|
              next if payload[:name] == "SCHEMA"

              record_sql(payload[:sql], extract_binds(payload))
            end
            ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
          else
            block.call
          end

        reads = finalize(@frame)
        @last_reads = reads
        [value, reads]
      ensure
        @tracking = previous_tracking
        @frame = previous_frame
      end

      # Programmatically record a read of `table` with optional `partitions`
      # hash (`{ "mailbox_id" => ["support"] }` or `{ "mailbox_id" => "support" }`).
      # Passing nil or {} marks the table read without partition narrowing.
      def record(table, partitions = nil)
        return unless @tracking && @frame

        name = normalize_identifier(table)
        return if name.empty? || internal_table?(name)

        normalized = {}
        if partitions.is_a?(Hash)
          partitions.each do |col, val|
            key = normalize_identifier(col)
            next if key.empty?

            values = val.is_a?(Array) ? val : [val]
            normalized[key] = values.compact.map(&:to_s).uniq.sort
          end
        end

        merge_table_read(@frame, name, normalized)
      end

      # Parse a SQL query and record any referenced user tables and sound
      # outer-WHERE partition constraints.
      def record_sql(sql, binds = nil)
        return unless @tracking && @frame

        query = strip_leading_comments(sql.to_s)
        return unless query.match?(/\A(?:SELECT|WITH)\b/i)

        tables = extract_tables(query)
        return if tables.empty?

        where_partitions = extract_outer_partitions(query, tables, binds)
        tables.each do |table|
          merge_table_read(@frame, table, where_partitions[table] || {})
        end
      end

      def serialize(reads)
        return "" unless reads.is_a?(Hash)

        JSON.generate(reads)
      end

      # Check whether a list of structured deltas (or nil wildcard) affects a
      # tracked reads snapshot. Returns true conservatively when deltas or reads
      # are unknown.
      def affects?(deltas, reads)
        return true if deltas.nil? || reads.nil?
        return false if deltas.empty?

        models = Array(reads["models"])
        tables = Array(reads["tables"])
        return false if models.empty? && tables.empty?

        partitions = reads["partitions"].is_a?(Hash) ? reads["partitions"] : {}
        deltas.any? do |delta|
          type = (delta["type"] || delta[:type]).to_s
          table = (delta["table"] || delta[:table]).to_s
          matched_key =
            if !type.empty? && models.include?(type)
              type
            elsif !table.empty? && tables.include?(table)
              table
            end
          next false unless matched_key

          constraints = partitions[matched_key] || (!table.empty? ? partitions[table] : nil)
          next true unless constraints.is_a?(Hash) && !constraints.empty?

          delta_matches_partitions?(delta, constraints)
        end
      end

      private

      def delta_matches_partitions?(delta, constraints)
        attrs = delta["attrs"] || delta[:attrs]
        op = (delta["op"] || delta[:op]).to_s
        changed_cols = Array(delta["changed_columns"] || delta[:changed_columns]).map(&:to_s)
        return true unless attrs.is_a?(Hash)

        constraints.each do |col, allowed|
          next if op == "update" && changed_cols.include?(col)
          next unless attrs.key?(col) || attrs.key?(col.to_sym)

          val = attrs.key?(col) ? attrs[col] : attrs[col.to_sym]
          next if val.nil?
          return false unless Array(allowed).include?(val.to_s)
        end
        true
      end

      def extract_binds(payload)
        raw = payload[:type_casted_binds]
        raw = raw.call if raw.respond_to?(:call)
        return raw if raw.is_a?(Array)

        binds = payload[:binds]
        return nil unless binds.is_a?(Array)

        binds.map { |bind| bind.respond_to?(:value_for_database) ? bind.value_for_database : bind }
      end

      def strip_leading_comments(sql)
        text = sql.lstrip
        loop do
          if text.start_with?("--")
            nl = text.index("\n")
            text = nl ? text[(nl + 1)..].lstrip : ""
          elsif text.start_with?("/*")
            stop = text.index("*/")
            text = stop ? text[(stop + 2)..].lstrip : ""
          else
            break
          end
        end
        text
      end

      def normalize_identifier(raw)
        str = raw.to_s.strip
        str = str.split(".").last.to_s if str.include?(".")
        str.delete('"`[]').downcase
      end

      def internal_table?(name)
        INTERNAL_TABLES.include?(name) || name.start_with?("sqlite_")
      end

      def extract_tables(sql)
        cleaned = mask_string_literals(sql)
        found = []
        cleaned.scan(/\b(?:FROM|JOIN)\s+([`"\[]?[A-Za-z_][A-Za-z0-9_]*[`"\]]?(?:\.[`"\[]?[A-Za-z_][A-Za-z0-9_]*[`"\]]?)?)/i) do |match|
          name = normalize_identifier(match[0])
          next if name.empty? || internal_table?(name) || SQL_KEYWORDS.include?(name)

          found << name unless found.include?(name)
        end
        found
      end

      def extract_outer_partitions(sql, tables, binds)
        result = {}
        where_clause, where_offset = extract_outer_where(sql)
        return result unless where_clause

        # A top-level OR in the outer WHERE means any single branch can match
        # rows outside the other branch's partition predicate.
        return result if contains_top_level_keyword?(where_clause, "OR")

        bind_index = count_placeholders(sql[0...where_offset])
        partition_columns = known_partition_columns
        primary_table = tables.length == 1 ? tables[0] : nil
        aliases = extract_outer_aliases(sql)

        split_top_level_and(where_clause).each do |part|
          clause = part.strip
          placeholders_in_clause = count_placeholders(clause)
          current_bind = bind_index
          bind_index += placeholders_in_clause

          # Strip balanced outer parens around a single conjunct like (mailbox_id = 'support').
          clause = unwrap_outer_parens(clause)
          next if contains_top_level_keyword?(clause, "OR")

          if (m = clause.match(/\A(?:([`"\[]?[A-Za-z_]\w*[`"\]]?)\.)?([`"\[]?[A-Za-z_]\w*[`"\]]?)\s*=\s*(.+)\z/i))
            table = resolve_table(m[1], primary_table, aliases, tables)
            col = normalize_identifier(m[2])
            next unless table && partition_column?(col, partition_columns)

            val = resolve_value(m[3].strip, binds, current_bind)
            next if val.nil?

            add_partition_value(result, table, col, val)
          elsif (m = clause.match(/\A(?:([`"\[]?[A-Za-z_]\w*[`"\]]?)\.)?([`"\[]?[A-Za-z_]\w*[`"\]]?)\s+IN\s*\((.+)\)\z/i))
            table = resolve_table(m[1], primary_table, aliases, tables)
            col = normalize_identifier(m[2])
            next unless table && partition_column?(col, partition_columns)

            values = resolve_in_values(m[3], binds, current_bind)
            next unless values && !values.empty?

            values.each { |v| add_partition_value(result, table, col, v) }
          end
        end

        result
      end

      def known_partition_columns
        cols = {}
        InstantRecord.syncable_models.each do |model|
          window = model.respond_to?(:instant_record_sync_window) ? model.instant_record_sync_window : nil
          cols[window.partition_by.to_s.downcase] = true if window && window.partition_by
          scope_col = model.respond_to?(:instant_record_sync_scope) ? model.instant_record_sync_scope : nil
          cols[scope_col.to_s.downcase] = true if scope_col
        end
        cols
      end

      def partition_column?(col, known)
        col == "id" || col.end_with?("_id") || known.key?(col)
      end

      def resolve_table(qualifier, primary_table, aliases, tables)
        if qualifier && !qualifier.empty?
          q = normalize_identifier(qualifier)
          return aliases[q] if aliases.key?(q)
          return q if tables.include?(q)
          return nil
        end
        primary_table
      end

      def extract_outer_aliases(sql)
        aliases = {}
        outer = top_level_text(sql)
        outer.scan(/\b(?:FROM|JOIN)\s+([`"\[]?[A-Za-z_]\w*[`"\]]?(?:\.[`"\[]?[A-Za-z_]\w*[`"\]]?)?)(?:\s+(?:AS\s+)?([`"\[]?[A-Za-z_]\w*[`"\]]?))?/i) do |tbl, als|
          table_name = normalize_identifier(tbl)
          next if table_name.empty? || internal_table?(table_name)

          aliases[table_name] = table_name
          if als && !als.empty?
            alias_name = normalize_identifier(als)
            aliases[alias_name] = table_name unless SQL_KEYWORDS.include?(alias_name)
          end
        end
        aliases
      end

      def add_partition_value(result, table, col, val)
        entry = (result[table] ||= {})
        list = (entry[col] ||= [])
        str = val.to_s
        list << str unless list.include?(str)
      end

      def resolve_value(expr, binds, bind_index)
        if expr == "?"
          return nil unless binds.is_a?(Array) && bind_index < binds.length

          val = binds[bind_index]
          val.nil? ? nil : val.to_s
        elsif (m = expr.match(/\A\$(\d+)\z/))
          idx = m[1].to_i - 1
          return nil unless binds.is_a?(Array) && idx >= 0 && idx < binds.length

          val = binds[idx]
          val.nil? ? nil : val.to_s
        elsif expr.start_with?("'") && expr.end_with?("'") && expr.length >= 2
          inner = expr[1..-2]
          # Ensure no unescaped quote inside (i.e. not `'a' OR 'b'`).
          return nil if inner.gsub("''", "").include?("'")

          inner.gsub("''", "'")
        elsif expr.match?(/\A-?\d+(?:\.\d+)?\z/)
          expr
        else
          nil
        end
      end

      def resolve_in_values(list_sql, binds, start_bind)
        items = split_top_level_commas(list_sql)
        return nil if items.empty?

        values = []
        idx = start_bind
        items.each do |item|
          token = item.strip
          val = resolve_value(token, binds, idx)
          idx += count_placeholders(token)
          return nil if val.nil?

          values << val
        end
        values
      end

      def extract_outer_where(sql)
        where_pos = find_top_level_keyword(sql, "WHERE")
        return [nil, 0] unless where_pos

        start = where_pos + 5
        rest = sql[start..]
        stop = rest.length
        %w[GROUP ORDER LIMIT HAVING UNION INTERSECT EXCEPT].each do |kw|
          pos = find_top_level_keyword(rest, kw)
          stop = pos if pos && pos < stop
        end
        semi = find_top_level_char(rest, ";")
        stop = semi if semi && semi < stop
        [rest[0...stop].strip, start]
      end

      def top_level_text(sql)
        out = +""
        depth = 0
        in_single = false
        i = 0
        len = sql.length
        while i < len
          ch = sql[i]
          if in_single
            if ch == "'"
              if i + 1 < len && sql[i + 1] == "'"
                i += 2
                next
              end
              in_single = false
            end
            out << " "
          elsif ch == "'"
            in_single = true
            out << " "
          elsif ch == "("
            depth += 1
            out << " "
          elsif ch == ")"
            depth -= 1 if depth > 0
            out << " "
          else
            out << (depth == 0 ? ch : " ")
          end
          i += 1
        end
        out
      end

      def mask_string_literals(sql)
        out = +""
        in_single = false
        i = 0
        len = sql.length
        while i < len
          ch = sql[i]
          if in_single
            if ch == "'"
              if i + 1 < len && sql[i + 1] == "'"
                out << "  "
                i += 2
                next
              end
              in_single = false
            end
            out << " "
          elsif ch == "'"
            in_single = true
            out << " "
          else
            out << ch
          end
          i += 1
        end
        out
      end

      def count_placeholders(sql)
        count = 0
        in_single = false
        i = 0
        len = sql.length
        while i < len
          ch = sql[i]
          if in_single
            if ch == "'"
              if i + 1 < len && sql[i + 1] == "'"
                i += 2
                next
              end
              in_single = false
            end
          elsif ch == "'"
            in_single = true
          elsif ch == "?"
            count += 1
          end
          i += 1
        end
        count
      end

      def find_top_level_keyword(sql, keyword)
        masked = top_level_text(sql)
        m = masked.match(/\b#{keyword}\b/i)
        m ? m.begin(0) : nil
      end

      def contains_top_level_keyword?(sql, keyword)
        !find_top_level_keyword(sql, keyword).nil?
      end

      def find_top_level_char(sql, target)
        masked = top_level_text(sql)
        masked.index(target)
      end

      def split_top_level_and(clause)
        masked = top_level_text(clause)
        parts = []
        cursor = 0
        masked.scan(/\bAND\b/i) do
          pos = Regexp.last_match.begin(0)
          parts << clause[cursor...pos]
          cursor = Regexp.last_match.end(0)
        end
        parts << clause[cursor..]
        parts
      end

      def split_top_level_commas(text)
        masked = top_level_text(text)
        parts = []
        cursor = 0
        i = 0
        len = masked.length
        while i < len
          if masked[i] == ","
            parts << text[cursor...i]
            cursor = i + 1
          end
          i += 1
        end
        parts << text[cursor..]
        parts
      end

      def unwrap_outer_parens(clause)
        text = clause.strip
        while text.start_with?("(") && text.end_with?(")")
          # Verify the opening paren matches the final closing paren.
          depth = 0
          in_single = false
          closes_early = false
          i = 0
          len = text.length
          while i < len
            ch = text[i]
            if in_single
              if ch == "'"
                if i + 1 < len && text[i + 1] == "'"
                  i += 2
                  next
                end
                in_single = false
              end
            elsif ch == "'"
              in_single = true
            elsif ch == "("
              depth += 1
            elsif ch == ")"
              depth -= 1
              if depth == 0 && i < len - 1
                closes_early = true
                break
              end
            end
            i += 1
          end
          break if closes_early

          text = text[1..-2].strip
        end
        text
      end

      def merge_table_read(frame, table, new_partitions)
        if !frame.key?(table)
          frame[table] = new_partitions
          return
        end

        existing = frame[table]
        return if existing.empty?

        if new_partitions.empty?
          frame[table] = {}
          return
        end

        intersected = {}
        existing.each do |col, vals|
          next unless new_partitions.key?(col)

          merged = (vals + new_partitions[col]).uniq.sort
          intersected[col] = merged
        end
        frame[table] = intersected
      end

      def finalize(frame)
        tables = frame.keys.sort
        table_to_models = {}
        InstantRecord.syncable_models.each do |model|
          tbl = model.table_name.to_s.downcase
          next if tbl.empty?

          list = (table_to_models[tbl] ||= [])
          list << model.name unless list.include?(model.name)
        end

        models = []
        partitions = {}

        tables.each do |table|
          matched = table_to_models[table] || []
          matched.each { |name| models << name unless models.include?(name) }

          constraints = frame[table]
          next if constraints.nil? || constraints.empty?

          sorted_constraints = {}
          constraints.keys.sort.each { |col| sorted_constraints[col] = constraints[col].sort }

          if matched.empty?
            partitions[table] = sorted_constraints
          else
            matched.each { |name| partitions[name] = sorted_constraints }
          end
        end

        {
          "tables" => tables,
          "models" => models.sort,
          "partitions" => partitions
        }
      end
    end
  end
end
