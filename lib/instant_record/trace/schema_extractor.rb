module InstantRecord
  module Trace
    # Extracts a compact `{ table_name => [column_names...] }` map from a Rails
    # `db/schema.rb` without requiring an active database connection. Used at
    # compile time (`VITE_TRACE_SCHEMA`) and by Ruby-side trace redaction.
    module SchemaExtractor
      CREATE_TABLE_RE = /^\s*create_table\s+["']([^"']+)["']/
      COLUMN_RE = /^\s*t\.(?:string|text|integer|bigint|float|decimal|boolean|datetime|timestamp|date|time|binary|json|jsonb|uuid)\s+["']([^"']+)["']/
      TIMESTAMPS_RE = /^\s*t\.timestamps\b/

      module_function

      def from_schema_rb(source)
        tables = {}
        current = nil
        source.to_s.each_line do |line|
          if (match = CREATE_TABLE_RE.match(line))
            current = match[1]
            tables[current] = ["id"]
          elsif current
            if line.match?(/^\s*end\s*$/)
              current = nil
            elsif (col = COLUMN_RE.match(line))
              name = col[1]
              tables[current] << name unless tables[current].include?(name)
            elsif TIMESTAMPS_RE.match?(line)
              %w[created_at updated_at].each do |ts|
                tables[current] << ts unless tables[current].include?(ts)
              end
            end
          end
        end
        tables
      end
    end
  end
end
