require "instant_record/read_tracker"

module InstantRecord
  # ReadTracker's SQL scanning with regular expressions instead of one character
  # at a time. The same answers, quirks included; read_tracker_scan_test.rb holds
  # the two together. Server only, so it is kept out of read_tracker.rb, which
  # the browser build compiles.
  #
  # Each method takes a plain String of valid UTF-8 and passes anything else to
  # the original, which decides how other encodings and broken bytes read (or
  # raise).
  module ReadTrackerScan
    # A single-quoted literal with its doubled quotes. One left open runs to the end.
    LITERAL = /'(?:[^']+|'')*+'?/
    # A literal, a run of anything else, or one paren.
    TOKEN = /'(?:[^']+|'')*+'?|[^'()]+|[()]/
    KEYWORDS = %w[WHERE GROUP ORDER LIMIT HAVING UNION INTERSECT EXCEPT OR].to_h { |kw| [kw, /\b#{kw}\b/i] }.freeze
    STOPS = %w[GROUP ORDER LIMIT HAVING UNION INTERSECT EXCEPT].map { |kw| KEYWORDS.fetch(kw) }.freeze

    private

    def scannable?(sql)
      sql.instance_of?(String) && sql.encoding == Encoding::UTF_8 && sql.valid_encoding?
    end

    # Every character outside literals and parens, and a space for each one
    # inside. A doubled quote leaves nothing, as in the original, so a mask can
    # be shorter than its text.
    def top_level_text(sql)
      return super unless scannable?(sql)
      return sql.dup unless sql.match?(/['()]/)

      depth = 0
      out = +""
      sql.scan(TOKEN) do |token|
        if token.start_with?("'")
          out << " " * literal_width(token)
        elsif token == "("
          depth += 1
          out << " "
        elsif token == ")"
          depth -= 1 if depth > 0
          out << " "
        else
          out << (depth == 0 ? token : " " * token.length)
        end
      end
      out
    end

    def literal_width(literal)
      quotes = literal.count("'")
      quotes < 3 ? literal.length : literal.length - 2 * ((quotes - 1) / 2)
    end

    def mask_string_literals(sql)
      return super unless scannable?(sql)
      return sql.dup unless sql.include?("'")

      sql.gsub(LITERAL) { |literal| " " * literal.length }
    end

    def count_placeholders(sql)
      return super unless scannable?(sql)
      return 0 unless sql.include?("?")

      (sql.include?("'") ? sql.gsub(LITERAL, "") : sql).count("?")
    end

    # What a mask leaves out becomes a space, so a keyword in the mask is also one
    # in the text: without one there, the mask is not needed.
    def find_top_level_keyword(sql, keyword)
      pattern = KEYWORDS[keyword]
      return super unless pattern && scannable?(sql)
      return nil unless sql.match?(pattern)

      top_level_text(sql).index(pattern)
    end

    def extract_outer_where(sql)
      return super unless scannable?(sql)

      where_pos = find_top_level_keyword(sql, "WHERE")
      return [nil, 0] unless where_pos

      start = where_pos + 5
      rest = sql[start..]
      masked = top_level_text(rest)
      stop = rest.length
      STOPS.each do |pattern|
        pos = masked.index(pattern)
        stop = pos if pos && pos < stop
      end
      semi = masked.index(";")
      stop = semi if semi && semi < stop
      [rest[0...stop].strip, start]
    end
  end

  ReadTracker.singleton_class.prepend(ReadTrackerScan)
end
