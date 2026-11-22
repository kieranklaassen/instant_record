require "base64"
require "digest"
require "json"
require "securerandom"
require "sqlite3"
require "tmpdir"

module InstantRecord
  module Trace
    # Schema-aware PII redactor for `.irtrace` files and embedded SQLite
    # checkpoints. Mirrors `compiled/web/src/redactor.js` and uses the real
    # `sqlite3` gem + VACUUM so deleted raw PII bytes never linger in freelist
    # pages.
    class Redactor
      STRUCTURAL_SAFE_COLUMNS = %w[
        id created_at updated_at deleted_at server_version sync_state cursor
        operation record_type record_id mutation_id base_version status kind
        type version has_more position done completed archived unread starred
        read_at sent_at published_at role state
      ].freeze

      DEFAULT_PII_PATTERNS = [
        /(^|_)e?mail(_|$|s$|_address$)/i,
        /(^|_)(phone|mobile|tel|telephone|fax)(_|$)/i,
        /(^|_)(password|passwd|pwd|secret|token|api_key|access_key|private_key|auth|credential|bearer)(_|$)/i,
        /(^|_)(ssn|social_security|tax_id|passport|license_number|national_id)(_|$)/i,
        /(^|_)(credit_card|card_number|cvv|cvc|iban|routing_number|account_number)(_|$)/i,
        /(^|_)(address|street|city|zip|postal|postcode)(_|$)/i,
        /(^|_)(ip|ip_address|user_agent)(_|$)/i,
        /(^|_)(cookie|session|csrf)(_|$)/i,
        /(^|_)(first_name|last_name|full_name|real_name|display_name|username|dob|birth_?date)(_|$)/i,
        /(^|_)(from_address|to_address|cc|bcc|reply_to|sender|recipient|from_email|to_email|author_email)(_|$)/i,
        /\Aidentity\z/i
      ].freeze

      EMAIL_VALUE_RE = /\A[^\s@]+@[^\s@]+\.[^\s@]+\z/
      SENSITIVE_ENV_RE = /(secret|token|key|password|passwd|auth|cookie|credential)/i

      def initialize(schema: {}, pii_columns: {}, safe_columns: {}, salt: nil)
        @schema = normalize_schema(schema)
        @explicit_pii = normalize_column_map(pii_columns)
        @explicit_safe = normalize_column_map(safe_columns)
        @salt = salt || SecureRandom.hex(16)
      end

      def pii_column?(table_or_model, column_name)
        col = column_name.to_s.downcase
        return false if col.empty?

        table = resolve_table_name(table_or_model)
        return false if @explicit_safe[table]&.include?(col) || @explicit_safe["*"]&.include?(col)
        return true if @explicit_pii[table]&.include?(col) || @explicit_pii["*"]&.include?(col)
        return false if STRUCTURAL_SAFE_COLUMNS.include?(col) || col.end_with?("_id", "_at")

        DEFAULT_PII_PATTERNS.any? { |pattern| pattern.match?(col) }
      end

      def pseudonymize(value, hint = "")
        return value if value.nil? || value == ""

        text = value.to_s
        hash = Digest::SHA256.hexdigest("#{@salt}:#{hint}:#{text}")[0, 12]
        lower_hint = hint.to_s.downcase
        if lower_hint.include?("email") || EMAIL_VALUE_RE.match?(text)
          "redacted-#{hash}@redacted.invalid"
        elsif lower_hint.include?("phone") || lower_hint.include?("tel") || lower_hint.include?("mobile")
          "+1-555-#{hash[0, 4]}"
        else
          "[redacted:#{hash}]"
        end
      end

      def redact_attributes(table_or_model, attrs)
        return attrs unless attrs.is_a?(Hash)

        attrs.each_with_object({}) do |(key, value), out|
          out[key] = redact_field_value(table_or_model, key.to_s, value)
        end
      end

      def redact_database(bytes)
        raw = bytes.b
        original_digest = Digest::SHA256.hexdigest(raw)
        redacted_columns = {}

        Dir.mktmpdir("irtrace-redact-") do |dir|
          file = File.join(dir, "checkpoint.sqlite3")
          File.binwrite(file, raw)
          db = SQLite3::Database.new(file)
          db.results_as_hash = true
          begin
            tables = db.execute("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
              .map { |row| row["name"] }

            tables.each do |table|
              next if %w[schema_migrations ar_internal_metadata].include?(table)

              if table == "instant_record_sync_metadata"
                redact_sync_metadata(db, table, redacted_columns)
              elsif table == "instant_record_outbox"
                redact_outbox_table(db, table, redacted_columns)
              else
                redact_user_table(db, table, redacted_columns)
              end
            end

            db.execute("VACUUM")
          ensure
            db.close
          end

          clean = File.binread(file)
          {
            bytes: clean,
            digest: Digest::SHA256.hexdigest(clean),
            original_digest: original_digest,
            redacted_columns: redacted_columns
          }
        end
      end

      def redact_trace(trace)
        copy = JSON.parse(JSON.generate(trace))
        checkpoint = copy["checkpoint"]
        if checkpoint.is_a?(Hash)
          if checkpoint["env"].is_a?(Hash)
            checkpoint["env"] = checkpoint["env"].each_with_object({}) do |(k, v), out|
              out[k] = SENSITIVE_ENV_RE.match?(k.to_s) ? pseudonymize(v, k) : v
            end
          end
          if checkpoint["cookies"].is_a?(Hash)
            checkpoint["cookies"] = checkpoint["cookies"].each_with_object({}) do |(k, v), out|
              out[k] = pseudonymize(v, "cookie:#{k}")
            end
          end
          if checkpoint["mode"] == "sqlite3" && checkpoint["data"].is_a?(String) && !checkpoint["data"].empty?
            db_bytes = Base64.strict_decode64(checkpoint["data"])
            result = redact_database(db_bytes)
            checkpoint["data"] = Base64.strict_encode64(result[:bytes])
            checkpoint["digest"] = result[:digest]
            checkpoint["originalDigest"] ||= result[:original_digest]
            checkpoint["byteLength"] = result[:bytes].bytesize
            checkpoint["redacted"] = true
            checkpoint["redactedColumns"] = result[:redacted_columns]
            copy["redaction"] ||= {}
            copy["redaction"]["enabled"] = true
            copy["redaction"]["strategy"] = "deterministic_pseudonym"
            copy["redaction"]["redactedColumns"] = (copy["redaction"]["redactedColumns"] || {}).merge(result[:redacted_columns])
          end
        end
        copy
      end

      private

      def quote_ident(name)
        %("#{name.to_s.gsub('"', '""')}")
      end

      def redact_sync_metadata(db, table, redacted_columns)
        db.execute("SELECT key, value FROM #{quote_ident(table)}").each do |row|
          next unless row["key"] == "identity" && row["value"] && !row["value"].empty?

          db.execute("UPDATE #{quote_ident(table)} SET value = ? WHERE key = ?", [pseudonymize(row["value"], "identity"), row["key"]])
          redacted_columns[table] = ((redacted_columns[table] || []) | ["identity"]).sort
        end
      end

      def redact_outbox_table(db, table, redacted_columns)
        db.execute("SELECT id, record_type, changes_payload FROM #{quote_ident(table)}").each do |row|
          payload = row["changes_payload"]
          next if payload.nil? || payload.empty?

          begin
            parsed = JSON.parse(payload)
            redacted = redact_attributes(row["record_type"] || "*", parsed)
            serialized = JSON.generate(redacted)
            next if serialized == payload

            db.execute("UPDATE #{quote_ident(table)} SET changes_payload = ? WHERE id = ?", [serialized, row["id"]])
            redacted_columns[table] = ((redacted_columns[table] || []) | ["changes_payload"]).sort
          rescue JSON::ParserError
            next
          end
        end
      end

      def redact_user_table(db, table, redacted_columns)
        cols = db.execute("PRAGMA table_info(#{quote_ident(table)})").map { |col| col["name"] }
        pii_cols = cols.select { |col| pii_column?(table, col) }
        return if pii_cols.empty?

        quoted_table = quote_ident(table)
        select_cols = pii_cols.map { |c| quote_ident(c) }.join(", ")
        set_clause = pii_cols.map { |c| "#{quote_ident(c)} = ?" }.join(", ")

        db.execute("SELECT rowid AS __ir_rowid, #{select_cols} FROM #{quoted_table}").each do |row|
          values = pii_cols.map do |col|
            val = row[col]
            val.nil? || val == "" ? val : pseudonymize(val, col)
          end
          db.execute("UPDATE #{quoted_table} SET #{set_clause} WHERE rowid = ?", values + [row["__ir_rowid"]])
        end

        redacted_columns[table] = pii_cols.sort
      end

      def redact_field_value(table_or_model, field, value)
        return value if value.nil?

        if pii_column?(table_or_model, field)
          return value.map { |v| pseudonymize(v, field) } if value.is_a?(Array)
          return pseudonymize(JSON.generate(value), field) if value.is_a?(Hash)

          return pseudonymize(value, field)
        end

        if value.is_a?(String) && EMAIL_VALUE_RE.match?(value.strip)
          return pseudonymize(value.strip, "email")
        end

        if value.is_a?(Hash)
          return redact_attributes(table_or_model, value)
        end

        if value.is_a?(Array)
          return value.map { |item| item.is_a?(Hash) ? redact_attributes(table_or_model, item) : item }
        end

        value
      end

      def resolve_table_name(table_or_model)
        return "*" if table_or_model.nil? || table_or_model.to_s.empty?

        lower = table_or_model.to_s.downcase
        return lower if @schema.key?(lower) || @explicit_pii.key?(lower) || @explicit_safe.key?(lower)

        guessed = model_to_table(table_or_model.to_s)
        return guessed if @schema.key?(guessed) || @explicit_pii.key?(guessed) || @explicit_safe.key?(guessed)

        guessed
      end

      def model_to_table(model_name)
        base = model_name.split("::").last.to_s
        snake = base
          .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
          .gsub(/([a-z\d])([A-Z])/, '\1_\2')
          .downcase
        if snake.end_with?("y") && !snake.match?(/[aeiou]y\z/)
          "#{snake[0..-2]}ies"
        elsif snake.match?(/(?:s|x|z|ch|sh)\z/)
          "#{snake}es"
        else
          "#{snake}s"
        end
      end

      def normalize_schema(schema)
        return {} unless schema.is_a?(Hash)

        schema.each_with_object({}) do |(table, cols), out|
          out[table.to_s.downcase] = Array(cols).map(&:to_s)
        end
      end

      def normalize_column_map(map)
        return {} unless map.is_a?(Hash)

        map.each_with_object({}) do |(table, cols), out|
          out[table.to_s.downcase] = Array(cols).map { |c| c.to_s.downcase }
        end
      end
    end
  end
end
