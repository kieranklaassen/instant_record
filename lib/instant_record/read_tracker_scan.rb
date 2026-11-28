# frozen_string_literal: true

require "instant_record/read_tracker"

module InstantRecord
  # ReadTracker's SQL scanning with regular expressions and byte-offset scans
  # instead of one character at a time. The same answers, quirks included;
  # read_tracker_scan_test.rb holds the two together. Server only, so it is kept
  # out of read_tracker.rb, which the browser build compiles.
  #
  # Each method takes a plain String of valid UTF-8 and passes anything else to
  # the original, which decides how other encodings and broken bytes read (or
  # raise).
  module ReadTrackerScan
    KEYWORDS = %w[WHERE GROUP ORDER LIMIT HAVING UNION INTERSECT EXCEPT OR].to_h { |kw| [kw, /\b#{kw}\b/i] }.freeze

    WHERE_RE = KEYWORDS.fetch("WHERE")
    OR_RE = KEYWORDS.fetch("OR")
    AND_RE = /\bAND\b/i
    STOP_RE = /\b(?:GROUP|ORDER|LIMIT|HAVING|UNION|INTERSECT|EXCEPT)\b|;/i
    STOP_NO_COMPOUND_RE = /\b(?:GROUP|ORDER|LIMIT|HAVING)\b|;/i
    COMPOUND_RE = /\b(?:UNION|INTERSECT|EXCEPT)\b/i
    SELECT_OR_WITH_RE = /\A(?:SELECT|WITH)\b/i
    FROM_QUOTE_RE = /\b(?:FROM|JOIN)\s*'/i
    TABLE_RE = /\b(?:FROM|JOIN)\s+(?:[`"\[]?[A-Za-z_][A-Za-z0-9_]*[`"\]]?\.)?[`"\[]?([A-Za-z_][A-Za-z0-9_]*)[`"\]]?/i
    ALIAS_RE = /\b(?:FROM|JOIN)\s+(?:[`"\[]?[A-Za-z_]\w*[`"\]]?\.)?[`"\[]?([A-Za-z_]\w*)[`"\]]?(?:\s+(?:AS\s+)?[`"\[]?([A-Za-z_]\w*)[`"\]]?)?/i
    PREDICATE_RE = /\A(?:[`"\[]?([A-Za-z_]\w*)[`"\]]?\.)?[`"\[]?([A-Za-z_]\w*)[`"\]]?(?:\s*=\s*(.+)|\s+IN\s*\((.+)\))\z/i
    ALL_QMARK_IN_RE = /\A\s*\?(?:\s*,\s*\?)*\s*\z/
    DOLLAR_BIND_RE = /\A\$(\d+)\z/
    NUMBER_RE = /\A-?\d+(?:\.\d+)?\z/

    INTERNAL_TABLE_SET = ReadTracker::INTERNAL_TABLES.to_h { |t| [t, true] }.freeze
    SQL_KEYWORD_SET = ReadTracker::SQL_KEYWORDS.to_h { |k| [k, true] }.freeze
    SPACES = Array.new(256) { |n| (" " * n).freeze }.freeze

    # Pure SQL structure cached per Fiber/Thread after a query is seen twice.
    # Dynamic partition columns (InstantRecord.syncable_models) and bind values
    # are always resolved fresh on every call.
    SqlPlan = Struct.new(:tables, :predicates)
    EMPTY_PREDICATES = [].freeze
    CACHE_KEY = :__instant_record_read_tracker_sql_cache__
    SEEN_KEY = :__instant_record_read_tracker_sql_seen__
    CACHE_MAX = 512
    CACHE_MAX_BYTES = 4096
    SEEN_MASK = 1023
    private_constant :SqlPlan, :EMPTY_PREDICATES, :CACHE_KEY, :SEEN_KEY, :CACHE_MAX, :CACHE_MAX_BYTES, :SEEN_MASK

    # The partition columns of one query, read when the first is looked for.
    class PartitionColumns
      def initialize(&read)
        @read = read
      end

      def key?(column) = (@columns ||= @read.call).key?(column)
    end
    private_constant :PartitionColumns

    def record_sql(sql, binds = nil)
      return unless @tracking && @frame

      str = sql.instance_of?(String) ? sql : sql.to_s
      return super unless scannable?(str)

      if str.bytesize <= CACHE_MAX_BYTES
        cache = (Thread.current[CACHE_KEY] ||= {})
        if (plan = cache[str])
          return apply_sql_plan(plan, binds)
        end

        seen = (Thread.current[SEEN_KEY] ||= Array.new(SEEN_MASK + 1))
        h = str.hash
        slot = h & SEEN_MASK
        if seen[slot] == h
          plan = compile_sql_plan(str)
          cache.shift if cache.size >= CACHE_MAX
          cache[str.dup.freeze] = plan
          return apply_sql_plan(plan, binds)
        else
          seen[slot] = h
        end
      end

      record_sql_uncached(str, binds)
    end

    private

    def scannable?(sql)
      sql.instance_of?(String) && sql.encoding == Encoding::UTF_8 && sql.valid_encoding?
    end

    def spaces(n)
      SPACES[n] || (" " * n)
    end

    def internal_table?(name)
      INTERNAL_TABLE_SET.key?(name) || name.start_with?("sqlite_")
    end

    def record_sql_uncached(str, binds)
      b0 = str.getbyte(0)
      return unless b0

      query = (b0 > 32 && b0 != 45 && b0 != 47) ? str : strip_leading_comments(str)
      return unless query.match?(SELECT_OR_WITH_RE)

      tables, single_from = extract_tables_with_count(query)
      return if tables.empty?

      where_partitions = extract_outer_partitions_fast(query, tables, binds, single_from)
      frame = @frame
      tables.each do |table|
        part = where_partitions[table]
        if part && !part.empty?
          merge_table_read(frame, table, part)
        elsif !frame.key?(table) || !frame[table].empty?
          frame[table] = {}
        end
      end
    end

    def compile_sql_plan(str)
      b0 = str.getbyte(0)
      return :ignore unless b0

      query = (b0 > 32 && b0 != 45 && b0 != 47) ? str : strip_leading_comments(str)
      return :ignore unless query.match?(SELECT_OR_WITH_RE)

      tables, single_from = extract_tables_with_count(query)
      return :ignore if tables.empty?

      tables.each(&:freeze).freeze
      predicates = compile_where_predicates(query, tables, single_from)
      SqlPlan.new(tables, predicates).freeze
    end

    # Parse outer WHERE into [outer, parts, bind_index, has_qmark, has_doubled],
    # or nil when no narrowable outer WHERE exists.
    def extract_where_context(sql)
      return nil unless sql.match?(WHERE_RE)

      nq = sql.byteindex("'")
      nl = sql.byteindex("(")
      nr = sql.byteindex(")")
      outer = (nq || nl || nr) ? top_level_text(sql) : sql

      where_pos = outer.index(WHERE_RE)
      return nil unless where_pos

      # The other parts of a compound query read rows the first WHERE does not limit.
      return nil if outer.match?(COMPOUND_RE)

      start = where_pos + 5
      has_doubled = !!(nq && sql.byteindex("''", nq))

      if has_doubled
        rest = sql[start..]
        masked_rest = top_level_text(rest)
        stop = masked_rest.index(STOP_RE) || rest.length
        where_clause = rest[0...stop].strip
        return nil if contains_top_level_keyword?(where_clause, "OR")

        parts = split_top_level_and(where_clause)
      else
        stop_pos = outer.ascii_only? ? outer.byteindex(STOP_NO_COMPOUND_RE, start) : outer.index(STOP_NO_COMPOUND_RE, start)
        if outer.ascii_only?
          masked_where = stop_pos ? outer.byteslice(start, stop_pos - start) : outer.byteslice(start, outer.bytesize - start)
        else
          masked_where = stop_pos ? outer[start...stop_pos] : outer[start..]
        end
        return nil if masked_where.match?(OR_RE)

        if sql.ascii_only?
          where_raw = stop_pos ? sql.byteslice(start, stop_pos - start) : sql.byteslice(start, sql.bytesize - start)
        else
          where_raw = stop_pos ? sql[start...stop_pos] : sql[start..]
        end
        parts = masked_where.match?(AND_RE) ? split_by_masked_and(where_raw, masked_where) : [where_raw]
      end

      has_qmark = !sql.byteindex("?").nil?
      bind_index =
        if !has_qmark
          0
        elsif sql.ascii_only?
          count_placeholders_upto(sql, start)
        else
          count_placeholders(sql[0...start])
        end

      [outer, parts, bind_index, has_qmark, has_doubled]
    end

    def compile_where_predicates(sql, tables, single_from)
      ctx = extract_where_context(sql)
      return EMPTY_PREDICATES unless ctx

      outer, parts, bind_index, has_qmark, has_doubled = ctx
      primary_table = tables.length == 1 ? tables[0] : nil
      aliases = nil
      compiled = []

      parts.each do |part|
        clause = part.strip
        current_bind = bind_index
        if has_qmark && clause.byteindex("?")
          bind_index += count_placeholders(clause)
        end

        unwrapped = false
        if clause.start_with?("(") && clause.end_with?(")")
          orig_len = clause.bytesize
          clause = unwrap_outer_parens(clause)
          unwrapped = clause.bytesize != orig_len
        end
        next if (unwrapped || has_doubled) && contains_top_level_keyword?(clause, "OR")

        next unless (m = PREDICATE_RE.match(clause))

        qual = m[1]
        if qual
          qual.downcase!
          if single_from && primary_table && qual == primary_table
            table = primary_table
          else
            aliases ||= extract_outer_aliases_from(outer)
            table = aliases[qual] || (tables.include?(qual) ? qual : nil)
          end
        else
          table = primary_table
        end
        next unless table

        col = m[2]
        col.downcase!
        col.freeze
        is_id = col == "id" || col.end_with?("_id")
        table_frozen = tables.find { |t| t == table } || table.freeze

        if (eq_rhs = m[3])
          kind, spec = compile_value_spec(eq_rhs, current_bind)
          compiled << [table_frozen, col, is_id, kind, spec].freeze
        else
          kind, spec = compile_in_spec(m[4], current_bind)
          compiled << [table_frozen, col, is_id, kind, spec].freeze
        end
      end

      compiled.empty? ? EMPTY_PREDICATES : compiled.freeze
    end

    def compile_value_spec(expr, bind_index)
      if expr == "?"
        [:eq_bind, bind_index]
      elsif expr.start_with?("'") && expr.end_with?("'") && expr.bytesize >= 2
        inner = expr.byteslice(1, expr.bytesize - 2)
        if inner.byteindex("'")
          return [:eq_nil, nil] if inner.gsub("''", "").byteindex("'")

          [:eq_lit, inner.gsub("''", "'").freeze]
        else
          [:eq_lit, inner.freeze]
        end
      elsif expr.start_with?("$") && (m = DOLLAR_BIND_RE.match(expr))
        idx = m[1].to_i - 1
        idx >= 0 ? [:eq_bind, idx] : [:eq_nil, nil]
      elsif expr.match?(NUMBER_RE)
        [:eq_lit, expr.dup.freeze]
      else
        [:eq_nil, nil]
      end
    end

    def compile_in_spec(list_sql, start_bind)
      if list_sql.match?(ALL_QMARK_IN_RE)
        return [:in_all_q, [start_bind, list_sql.count("?")].freeze]
      end

      items = split_top_level_commas(list_sql)
      return [:in_nil, nil] if items.empty?

      specs = []
      idx = start_bind
      items.each do |item|
        token = item.strip
        if token == "?"
          specs << idx
          idx += 1
        elsif token.start_with?("'") && token.end_with?("'") && token.bytesize >= 2
          inner = token.byteslice(1, token.bytesize - 2)
          if inner.byteindex("'")
            return [:in_nil, nil] if inner.gsub("''", "").byteindex("'")

            specs << inner.gsub("''", "'").freeze
          else
            specs << inner.freeze
          end
        elsif token.start_with?("$") && (m = DOLLAR_BIND_RE.match(token))
          b_idx = m[1].to_i - 1
          return [:in_nil, nil] if b_idx < 0

          specs << b_idx
        elsif token.match?(NUMBER_RE)
          specs << token.dup.freeze
        else
          return [:in_nil, nil]
        end
      end
      [:in_mixed, specs.freeze]
    end

    def eval_predicate_into(target_cols, col, kind, spec, binds, binds_is_array, binds_len)
      if kind == :eq_bind
        return unless binds_is_array && spec < binds_len

        val = binds[spec]
        return if val.nil?

        (target_cols[col] ||= []) << val.to_s
      elsif kind == :eq_lit
        (target_cols[col] ||= []) << spec.dup
      elsif kind == :in_all_q
        start_b = spec[0]
        count = spec[1]
        return unless binds_is_array && start_b + count <= binds_len

        vals = Array.new(count)
        i = 0
        while i < count
          v = binds[start_b + i]
          return if v.nil?

          vals[i] = v.to_s
          i += 1
        end
        list = target_cols[col]
        if list
          list.concat(vals)
        else
          target_cols[col] = vals
        end
      elsif kind == :in_mixed
        n = spec.length
        vals = Array.new(n)
        i = 0
        while i < n
          item = spec[i]
          if item.is_a?(Integer)
            return unless binds_is_array && item < binds_len

            v = binds[item]
            return if v.nil?

            vals[i] = v.to_s
          else
            vals[i] = item.dup
          end
          i += 1
        end
        list = target_cols[col]
        if list
          list.concat(vals)
        else
          target_cols[col] = vals
        end
      end
    end

    def apply_sql_plan(plan, binds)
      return if plan.equal?(:ignore)

      tables = plan.tables
      preds = plan.predicates
      frame = @frame

      if preds.empty?
        tables.each do |table|
          frame[table] = {} if !frame.key?(table) || !frame[table].empty?
        end
        return
      end

      syncable_models = nil
      binds_is_array = binds.is_a?(Array)
      binds_len = binds_is_array ? binds.length : 0

      if tables.length == 1
        table = tables[0]
        table_parts = {}
        preds.each do |pred|
          unless pred[2]
            syncable_models ||= InstantRecord.syncable_models
            next unless model_partition_column?(syncable_models, pred[1])
          end
          next unless pred[0] == table

          eval_predicate_into(table_parts, pred[1], pred[3], pred[4], binds, binds_is_array, binds_len)
        end

        if table_parts.empty?
          frame[table] = {} if !frame.key?(table) || !frame[table].empty?
        else
          table_parts.each_value { |vals| vals.uniq! if vals.length > 1 }
          merge_table_read(frame, table, table_parts)
        end
        return
      end

      where_partitions = nil
      preds.each do |pred|
        unless pred[2]
          syncable_models ||= InstantRecord.syncable_models
          next unless model_partition_column?(syncable_models, pred[1])
        end
        entry = ((where_partitions ||= {})[pred[0]] ||= {})
        eval_predicate_into(entry, pred[1], pred[3], pred[4], binds, binds_is_array, binds_len)
      end

      if where_partitions
        where_partitions.each_value { |cols| cols.each_value { |vals| vals.uniq! if vals.length > 1 } }
        tables.each do |table|
          part = where_partitions[table]
          if part && !part.empty?
            merge_table_read(frame, table, part)
          elsif !frame.key?(table) || !frame[table].empty?
            frame[table] = {}
          end
        end
      else
        tables.each do |table|
          frame[table] = {} if !frame.key?(table) || !frame[table].empty?
        end
      end
    end

    # Every character outside literals and parens, and a space for each one
    # inside. A doubled quote leaves nothing, as in the original, so a mask can
    # be shorter than its text.
    def top_level_text(sql)
      return super unless scannable?(sql)

      nq = sql.byteindex("'")
      nl = sql.byteindex("(")
      nr = sql.byteindex(")")
      return sql.dup unless nq || nl || nr

      ascii = sql.ascii_only?
      has_dd = nq && sql.byteindex("''", nq)
      out = sql.dup
      len = sql.bytesize

      if ascii && !has_dd
        unless nl || nr
          pos = nq
          while pos
            close = sql.byteindex("'", pos + 1)
            if close
              out[pos, close - pos + 1] = spaces(close - pos + 1)
              pos = sql.byteindex("'", close + 1)
            else
              out[pos, len - pos] = spaces(len - pos)
              break
            end
          end
          return out
        end

        depth = 0
        paren_start = 0
        loop do
          idx = nq
          kind = 0
          if nl && (!idx || nl < idx)
            idx = nl
            kind = 1
          end
          if nr && (!idx || nr < idx)
            idx = nr
            kind = 2
          end
          break unless idx

          if kind == 0
            close = sql.byteindex("'", idx + 1)
            end_pos = close ? close + 1 : len
            out[idx, end_pos - idx] = spaces(end_pos - idx) if depth == 0
            nq = close ? sql.byteindex("'", end_pos) : nil
            nl = sql.byteindex("(", end_pos) if nl && nl < end_pos
            nr = sql.byteindex(")", end_pos) if nr && nr < end_pos
          elsif kind == 1
            paren_start = idx if depth == 0
            depth += 1
            nl = sql.byteindex("(", idx + 1)
          else
            if depth > 0
              depth -= 1
              out[paren_start, idx - paren_start + 1] = spaces(idx - paren_start + 1) if depth == 0
            else
              out.setbyte(idx, 32)
            end
            nr = sql.byteindex(")", idx + 1)
          end
        end
        out[paren_start, len - paren_start] = spaces(len - paren_start) if depth > 0
        return out
      end

      # In-place bytesplice scanner for non-ASCII UTF-8 and/or doubled quotes ''
      shift = 0
      depth = 0
      paren_start = 0
      paren_doubled = 0

      loop do
        idx = nq
        kind = 0
        if nl && (!idx || nl < idx)
          idx = nl
          kind = 1
        end
        if nr && (!idx || nr < idx)
          idx = nr
          kind = 2
        end
        break unless idx

        if kind == 0
          close = sql.byteindex("'", idx + 1)
          doubled = 0
          while close && close + 1 < len && sql.getbyte(close + 1) == 39
            doubled += 1
            close = sql.byteindex("'", close + 2)
          end
          end_pos = close ? close + 1 : len
          if depth == 0
            blen = end_pos - idx
            slen = (ascii ? blen : sql.byteslice(idx, blen).length) - 2 * doubled
            out.bytesplice(idx - shift, blen, spaces(slen))
            shift += blen - slen
          else
            paren_doubled += doubled
          end
          nq = close ? sql.byteindex("'", end_pos) : nil
          nl = sql.byteindex("(", end_pos) if nl && nl < end_pos
          nr = sql.byteindex(")", end_pos) if nr && nr < end_pos
        elsif kind == 1
          if depth == 0
            paren_start = idx
            paren_doubled = 0
          end
          depth += 1
          nl = sql.byteindex("(", idx + 1)
        else
          if depth > 0
            depth -= 1
            if depth == 0
              blen = idx + 1 - paren_start
              slen = (ascii ? blen : sql.byteslice(paren_start, blen).length) - 2 * paren_doubled
              out.bytesplice(paren_start - shift, blen, spaces(slen))
              shift += blen - slen
            end
          else
            out.setbyte(idx - shift, 32)
          end
          nr = sql.byteindex(")", idx + 1)
        end
      end

      if depth > 0
        blen = len - paren_start
        slen = (ascii ? blen : sql.byteslice(paren_start, blen).length) - 2 * paren_doubled
        out.bytesplice(paren_start - shift, blen, spaces(slen))
      end
      out
    end

    def mask_string_literals(sql)
      return super unless scannable?(sql)

      nq = sql.byteindex("'")
      return sql.dup unless nq

      len = sql.bytesize
      out = sql.dup
      if sql.ascii_only?
        pos = nq
        while pos
          close = sql.byteindex("'", pos + 1)
          while close && close + 1 < len && sql.getbyte(close + 1) == 39
            close = sql.byteindex("'", close + 2)
          end
          if close
            out[pos, close - pos + 1] = spaces(close - pos + 1)
            pos = sql.byteindex("'", close + 1)
          else
            out[pos, len - pos] = spaces(len - pos)
            break
          end
        end
        return out
      end

      shift = 0
      pos = nq
      while pos
        close = sql.byteindex("'", pos + 1)
        while close && close + 1 < len && sql.getbyte(close + 1) == 39
          close = sql.byteindex("'", close + 2)
        end
        end_pos = close ? close + 1 : len
        blen = end_pos - pos
        slen = sql.byteslice(pos, blen).length
        out.bytesplice(pos - shift, blen, spaces(slen))
        shift += blen - slen
        pos = close ? sql.byteindex("'", end_pos) : nil
      end
      out
    end

    def count_placeholders(sql)
      return super unless scannable?(sql)

      nmark = sql.byteindex("?")
      return 0 unless nmark

      nq = sql.byteindex("'")
      return sql.count("?") unless nq

      count_placeholders_between(sql, nmark, nq, sql.bytesize)
    end

    def count_placeholders_upto(sql, limit_bytes)
      nmark = sql.byteindex("?")
      return 0 unless nmark && nmark < limit_bytes

      nq = sql.byteindex("'")
      if !nq || nq >= limit_bytes
        count = 1
        while (nmark = sql.byteindex("?", nmark + 1)) && nmark < limit_bytes
          count += 1
        end
        return count
      end

      count_placeholders_between(sql, nmark, nq, limit_bytes)
    end

    def count_placeholders_between(sql, nmark, nq, limit_bytes)
      count = 0
      while nmark && nmark < limit_bytes
        if nq && nq < nmark
          close = sql.byteindex("'", nq + 1)
          while close && close + 1 < limit_bytes && sql.getbyte(close + 1) == 39
            close = sql.byteindex("'", close + 2)
          end
          break unless close && close < limit_bytes

          pos = close + 1
          nq = sql.byteindex("'", pos)
          nmark = sql.byteindex("?", pos) if nmark < pos
        else
          count += 1
          nmark = sql.byteindex("?", nmark + 1)
        end
      end
      count
    end

    # What a mask leaves out becomes a space, so a keyword in the mask is also one
    # in the text: without one there, the mask is not needed.
    def find_top_level_keyword(sql, keyword)
      pattern = KEYWORDS[keyword]
      return super unless pattern && scannable?(sql)
      return nil unless sql.match?(pattern)

      nq = sql.byteindex("'")
      nl = sql.byteindex("(")
      nr = sql.byteindex(")")
      first_special = nq
      first_special = nl if nl && (!first_special || nl < first_special)
      first_special = nr if nr && (!first_special || nr < first_special)

      return sql.index(pattern) unless first_special

      pos_byte = sql.byteindex(pattern)
      if pos_byte < first_special
        return sql.ascii_only? ? pos_byte : sql.byteslice(0, pos_byte).length
      end

      top_level_text(sql).index(pattern)
    end

    def extract_outer_where(sql)
      return super unless scannable?(sql)
      return [nil, 0] unless sql.match?(WHERE_RE)

      nq = sql.byteindex("'")
      nl = sql.byteindex("(")
      nr = sql.byteindex(")")
      first_special = nq
      first_special = nl if nl && (!first_special || nl < first_special)
      first_special = nr if nr && (!first_special || nr < first_special)

      unless first_special
        where_pos = sql.index(WHERE_RE)
        return [nil, 0] unless where_pos

        start = where_pos + 5
        if sql.ascii_only?
          stop_pos = sql.byteindex(STOP_RE, start)
          slice = stop_pos ? sql.byteslice(start, stop_pos - start) : sql.byteslice(start, sql.bytesize - start)
        else
          stop_pos = sql.index(STOP_RE, start)
          slice = stop_pos ? sql[start...stop_pos] : sql[start..]
        end
        return [slice.strip, start]
      end

      where_byte = sql.byteindex(WHERE_RE)
      return [nil, 0] unless where_byte

      # Fast path: WHERE appears before the first quote or paren, so we only
      # need to mask the tail after WHERE (or skip masking if no stop keyword).
      if where_byte < first_special
        start_byte = where_byte + 5
        start = sql.ascii_only? ? start_byte : sql.byteslice(0, start_byte).length
        rest = sql.byteslice(start_byte, sql.bytesize - start_byte)
        return [rest.strip, start] unless rest.match?(STOP_RE)

        masked = top_level_text(rest)
        stop = masked.index(STOP_RE)
        slice = stop ? (rest.ascii_only? ? rest.byteslice(0, stop) : rest[0...stop]) : rest
        return [slice.strip, start]
      end

      outer = top_level_text(sql)
      where_pos = outer.index(WHERE_RE)
      return [nil, 0] unless where_pos

      start = where_pos + 5
      unless nq && sql.byteindex("''", nq)
        stop_pos = outer.ascii_only? ? outer.byteindex(STOP_RE, start) : outer.index(STOP_RE, start)
        if sql.ascii_only?
          slice = stop_pos ? sql.byteslice(start, stop_pos - start) : sql.byteslice(start, sql.bytesize - start)
        else
          slice = stop_pos ? sql[start...stop_pos] : sql[start..]
        end
        return [slice.strip, start]
      end

      rest = sql[start..]
      return [rest.strip, start] unless rest.match?(STOP_RE)

      masked = top_level_text(rest)
      stop = masked.index(STOP_RE) || rest.length
      [rest[0...stop].strip, start]
    end

    def split_top_level_and(clause)
      return super unless scannable?(clause)
      return [clause.dup] unless clause.match?(AND_RE)

      unless clause.byteindex("'") || clause.byteindex("(") || clause.byteindex(")")
        return clause.split(AND_RE, -1)
      end

      split_by_masked_and(clause, top_level_text(clause))
    end

    def split_by_masked_and(clause, masked)
      return [clause.dup] unless masked.match?(AND_RE)

      parts = []
      cursor = 0
      if clause.ascii_only? && masked.ascii_only?
        while (m = AND_RE.match(masked, cursor))
          pos = m.begin(0)
          parts << clause.byteslice(cursor, pos - cursor)
          cursor = m.end(0)
        end
        parts << clause.byteslice(cursor, clause.bytesize - cursor)
      else
        masked.scan(AND_RE) do
          pos = Regexp.last_match.begin(0)
          parts << clause[cursor...pos]
          cursor = Regexp.last_match.end(0)
        end
        parts << clause[cursor..]
      end
      parts
    end

    # A place in the mask is used as a place in the text, as in the original, even
    # where the mask is shorter. Text that is not ASCII is cut in UTF-32, where a
    # place is found without reading what comes before it.
    def split_top_level_commas(text)
      return super unless scannable?(text)

      nc = text.byteindex(",")
      return [text.dup] unless nc

      nq = text.byteindex("'")
      nl = text.byteindex("(")
      nr = text.byteindex(")")
      return text.split(",", -1) unless nq || nl || nr

      # Without doubled quotes '', top-level commas sit at exact byte offsets
      # for both ASCII and non-ASCII valid UTF-8, avoiding a full mask pass.
      unless nq && text.byteindex("''", nq)
        parts = []
        len = text.bytesize
        cursor = 0
        depth = 0
        loop do
          idx = nc
          kind = 3
          if nq && (!idx || nq < idx)
            idx = nq
            kind = 0
          end
          if nl && (!idx || nl < idx)
            idx = nl
            kind = 1
          end
          if nr && (!idx || nr < idx)
            idx = nr
            kind = 2
          end
          break unless idx

          if kind == 3
            if depth == 0
              parts << text.byteslice(cursor, idx - cursor)
              cursor = idx + 1
            end
            nc = text.byteindex(",", idx + 1)
            break unless nc
          elsif kind == 0
            close = text.byteindex("'", idx + 1)
            break unless close

            end_pos = close + 1
            nq = text.byteindex("'", end_pos)
            nl = text.byteindex("(", end_pos) if nl && nl < end_pos
            nr = text.byteindex(")", end_pos) if nr && nr < end_pos
            nc = text.byteindex(",", end_pos) if nc && nc < end_pos
            break unless nc
          elsif kind == 1
            depth += 1
            nl = text.byteindex("(", idx + 1)
          else
            depth -= 1 if depth > 0
            nr = text.byteindex(")", idx + 1)
          end
        end
        parts << text.byteslice(cursor, len - cursor)
        return parts
      end

      masked = top_level_text(text)
      if text.ascii_only? && masked.ascii_only?
        parts = []
        cursor = 0
        while (pos = masked.byteindex(",", cursor))
          parts << text.byteslice(cursor, pos - cursor)
          cursor = pos + 1
        end
        parts << text.byteslice(cursor, text.bytesize - cursor)
        return parts
      end

      if text.bytesize <= 256
        parts = []
        cursor = 0
        while (pos = masked.index(",", cursor))
          parts << text[cursor...pos]
          cursor = pos + 1
        end
        parts << text[cursor..]
        return parts
      end

      wide = text.encode(Encoding::UTF_32LE)
      lengths = masked.split(",", -1).map(&:length)
      lengths.pop
      cursor = 0
      parts = lengths.map do |length|
        part = wide[cursor, length]
        cursor += length + 1
        part
      end
      parts << wide[cursor..]
      parts.map { |part| part.encode(Encoding::UTF_8) }
    end

    def unwrap_outer_parens(clause)
      return super unless scannable?(clause)

      text = clause.strip
      while text.start_with?("(") && text.end_with?(")")
        len = text.bytesize
        depth = 1
        nq = text.byteindex("'", 1)
        nl = text.byteindex("(", 1)
        nr = text.byteindex(")", 1)
        closes_early = false
        loop do
          idx = nq
          kind = 0
          if nl && (!idx || nl < idx)
            idx = nl
            kind = 1
          end
          if nr && (!idx || nr < idx)
            idx = nr
            kind = 2
          end
          break unless idx

          if kind == 0
            close = text.byteindex("'", idx + 1)
            while close && close + 1 < len && text.getbyte(close + 1) == 39
              close = text.byteindex("'", close + 2)
            end
            break unless close

            end_pos = close + 1
            nq = text.byteindex("'", end_pos)
            nl = text.byteindex("(", end_pos) if nl && nl < end_pos
            nr = text.byteindex(")", end_pos) if nr && nr < end_pos
          elsif kind == 1
            depth += 1
            nl = text.byteindex("(", idx + 1)
          else
            depth -= 1
            if depth == 0 && idx < len - 1
              closes_early = true
              break
            end
            nr = text.byteindex(")", idx + 1)
          end
        end
        break if closes_early

        text = text.byteslice(1, len - 2).strip
      end
      text
    end

    def extract_tables(sql)
      return super unless scannable?(sql)

      tables, = extract_tables_with_count(sql)
      tables
    end

    def extract_tables_with_count(sql)
      nq = sql.byteindex("'")
      cleaned =
        if !nq || (!sql.byteindex(TABLE_RE, nq) && !sql.match?(FROM_QUOTE_RE))
          sql
        else
          mask_string_literals(sql)
        end
      found = []
      matches = 0
      pos = 0
      while (m = TABLE_RE.match(cleaned, pos))
        matches += 1
        name = m[1]
        name.downcase!
        pos = m.end(0)
        next if INTERNAL_TABLE_SET.key?(name) || name.start_with?("sqlite_") || SQL_KEYWORD_SET.key?(name)

        found << name unless found.include?(name)
      end
      [found, matches == 1 && found.length == 1 && !sql.byteindex("(")]
    end

    def extract_outer_aliases(sql)
      return super unless scannable?(sql)

      outer = (sql.byteindex("'") || sql.byteindex("(") || sql.byteindex(")")) ? top_level_text(sql) : sql
      extract_outer_aliases_from(outer)
    end

    def extract_outer_aliases_from(outer)
      aliases = {}
      pos = 0
      while (m = ALIAS_RE.match(outer, pos))
        pos = m.end(0)
        table_name = m[1]
        table_name.downcase!
        next if INTERNAL_TABLE_SET.key?(table_name) || table_name.start_with?("sqlite_")

        aliases[table_name] = table_name
        if (als = m[2])
          als.downcase!
          aliases[als] = table_name unless SQL_KEYWORD_SET.key?(als)
        end
      end
      aliases
    end

    def extract_outer_partitions(sql, tables, binds)
      unless scannable?(sql)
        return super.each_value { |columns| columns.each_value(&:uniq!) }
      end

      extract_outer_partitions_fast(sql, tables, binds, false)
    end

    def extract_outer_partitions_fast(sql, tables, binds, single_from)
      result = {}
      ctx = extract_where_context(sql)
      return result unless ctx

      outer, parts, bind_index, has_qmark, has_doubled = ctx
      primary_table = tables.length == 1 ? tables[0] : nil
      aliases = nil
      syncable_models = nil

      parts.each do |part|
        clause = part.strip
        current_bind = bind_index
        if has_qmark && clause.byteindex("?")
          bind_index += count_placeholders(clause)
        end

        unwrapped = false
        if clause.start_with?("(") && clause.end_with?(")")
          orig_len = clause.bytesize
          clause = unwrap_outer_parens(clause)
          unwrapped = clause.bytesize != orig_len
        end
        next if (unwrapped || has_doubled) && contains_top_level_keyword?(clause, "OR")

        next unless (m = PREDICATE_RE.match(clause))

        qual = m[1]
        if qual
          qual.downcase!
          if single_from && primary_table && qual == primary_table
            table = primary_table
          else
            aliases ||= extract_outer_aliases_from(outer)
            table = aliases[qual] || (tables.include?(qual) ? qual : nil)
          end
        else
          table = primary_table
        end
        next unless table

        col = m[2]
        col.downcase!
        unless col == "id" || col.end_with?("_id")
          syncable_models ||= InstantRecord.syncable_models
          next unless model_partition_column?(syncable_models, col)
        end

        if (eq_rhs = m[3])
          val = resolve_value(eq_rhs, binds, current_bind)
          next if val.nil?

          add_partition_value(result, table, col, val)
        else
          values = resolve_in_values(m[4], binds, current_bind)
          next unless values && !values.empty?

          entry = (result[table] ||= {})
          list = (entry[col] ||= [])
          values.each { |v| list << v.to_s }
        end
      end

      result.each_value do |columns|
        columns.each_value { |vals| vals.uniq! if vals.length > 1 }
      end
      result
    end

    def model_partition_column?(models, col)
      models.each do |model|
        if model.respond_to?(:instant_record_sync_window)
          window = model.instant_record_sync_window
          if window && (pb = window.partition_by)
            name = pb.is_a?(Symbol) ? pb.name : pb.to_s
            return true if name.casecmp?(col)
          end
        end
        if model.respond_to?(:instant_record_sync_scope) && (scope_col = model.instant_record_sync_scope)
          name = scope_col.is_a?(Symbol) ? scope_col.name : scope_col.to_s
          return true if name.casecmp?(col)
        end
      end
      false
    end

    def resolve_value(expr, binds, bind_index)
      return super unless scannable?(expr)

      if expr == "?"
        return nil unless binds.is_a?(Array) && bind_index < binds.length

        val = binds[bind_index]
        val.nil? ? nil : val.to_s
      elsif expr.start_with?("'") && expr.end_with?("'") && expr.bytesize >= 2
        inner = expr.byteslice(1, expr.bytesize - 2)
        if inner.byteindex("'")
          return nil if inner.gsub("''", "").byteindex("'")

          inner.gsub("''", "'")
        else
          inner
        end
      elsif expr.start_with?("$") && (m = DOLLAR_BIND_RE.match(expr))
        idx = m[1].to_i - 1
        return nil unless binds.is_a?(Array) && idx >= 0 && idx < binds.length

        val = binds[idx]
        val.nil? ? nil : val.to_s
      elsif expr.match?(NUMBER_RE)
        expr
      end
    end

    def resolve_in_values(list_sql, binds, start_bind)
      return super unless scannable?(list_sql)

      if list_sql.match?(ALL_QMARK_IN_RE)
        count = list_sql.count("?")
        return nil unless binds.is_a?(Array) && start_bind + count <= binds.length

        values = Array.new(count)
        i = 0
        while i < count
          val = binds[start_bind + i]
          return nil if val.nil?

          values[i] = val.to_s
          i += 1
        end
        return values
      end

      items = split_top_level_commas(list_sql)
      return nil if items.empty?

      values = []
      idx = start_bind
      items.each do |item|
        token = item.strip
        val = resolve_value(token, binds, idx)
        return nil if val.nil?

        idx += 1 if token == "?"
        values << val
      end
      values
    end

    def add_partition_value(result, table, col, val)
      ((result[table] ||= {})[col] ||= []) << val.to_s
    end

    # Naming the partition columns asks every model. The original does so for each
    # query with a WHERE, yet looks only for a column that is not an id.
    def known_partition_columns
      PartitionColumns.new { super }
    end
  end

  ReadTracker.singleton_class.prepend(ReadTrackerScan)
end
