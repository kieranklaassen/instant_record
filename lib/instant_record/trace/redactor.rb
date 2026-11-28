# frozen_string_literal: true

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

      STRUCTURAL_SAFE_SET = STRUCTURAL_SAFE_COLUMNS.each_with_object({}) { |col, set| set[col] = true }.freeze
      DEFAULT_PII_PATTERN = Regexp.union(*DEFAULT_PII_PATTERNS).freeze
      GOV_ID_RE = /(^|_)(tax|national)_id\z/i
      SQLITE_HEADER_PREFIX = "SQLite format 3\0".b.freeze
      IN_MEMORY_SQLITE_SUPPORTED =
        SQLite3::Database.method_defined?(:deserialize) &&
        SQLite3::Database.method_defined?(:serialize)
      CACHE_LIMIT = 4096

      private_constant :STRUCTURAL_SAFE_SET, :DEFAULT_PII_PATTERN, :GOV_ID_RE,
        :SQLITE_HEADER_PREFIX, :IN_MEMORY_SQLITE_SUPPORTED, :CACHE_LIMIT

      def initialize(schema: {}, pii_columns: {}, safe_columns: {}, salt: nil)
        @schema = normalize_schema(schema)
        @explicit_pii = normalize_column_map(pii_columns)
        @explicit_safe = normalize_column_map(safe_columns)
        @explicit_safe_wildcard = @explicit_safe["*"]
        @explicit_pii_wildcard = @explicit_pii["*"]
        @salt = salt || SecureRandom.hex(16)
        @email_hint_prefix = "#{@salt}:email:".freeze
        @table_name_cache = {}
        @pii_cache = {}
        @hint_cache = {}
      end

      def pii_column?(table_or_model, column_name)
        table = resolve_table_name(table_or_model)
        table_cache = pii_cache_for(table)
        cached = table_cache[column_name]
        return cached unless cached.nil?

        result = compute_pii_column?(table, column_name)
        if column_name.is_a?(String) || column_name.is_a?(Symbol)
          table_cache.clear if table_cache.size >= CACHE_LIMIT
          table_cache[column_name] = result
        end
        result
      end

      def pseudonymize(value, hint = "")
        return value if value.nil? || value == ""

        prefix, kind = hint_info(hint)
        pseudonymize_fast(Digest::SHA256.new, prefix, kind, value)
      end

      def redact_attributes(table_or_model, attrs)
        return attrs unless attrs.is_a?(Hash)

        table = resolve_table_name(table_or_model)
        redact_attributes_for_table(table, pii_cache_for(table), attrs, Digest::SHA256.new)
      end

      def redact_database(bytes)
        raw = bytes.encoding == Encoding::BINARY ? bytes : bytes.b
        original_digest = Digest::SHA256.hexdigest(raw)
        redacted_columns = {}

        clean =
          if can_deserialize_in_memory?(raw)
            redact_database_in_memory(raw, redacted_columns)
          else
            redact_database_in_tempfile(raw, redacted_columns)
          end

        {
          bytes: clean,
          digest: Digest::SHA256.hexdigest(clean),
          original_digest: original_digest,
          redacted_columns: redacted_columns
        }
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

      def can_deserialize_in_memory?(raw)
        IN_MEMORY_SQLITE_SUPPORTED &&
          raw.bytesize >= 100 &&
          raw.start_with?(SQLITE_HEADER_PREFIX) &&
          raw.getbyte(18) != 2 &&
          raw.getbyte(19) != 2
      end

      def redact_database_in_memory(raw, redacted_columns)
        db = SQLite3::Database.new(":memory:")
        begin
          db.deserialize(raw)
          db.execute("PRAGMA temp_store = MEMORY")
          redact_open_database(db, redacted_columns)
          db.serialize
        ensure
          db.close
        end
      end

      def redact_database_in_tempfile(raw, redacted_columns)
        Dir.mktmpdir("irtrace-redact-") do |dir|
          file = File.join(dir, "checkpoint.sqlite3")
          File.binwrite(file, raw)
          db = SQLite3::Database.new(file)
          begin
            db.execute("PRAGMA synchronous = OFF")
            db.execute("PRAGMA temp_store = MEMORY")
            redact_open_database(db, redacted_columns)
          ensure
            db.close
          end

          File.binread(file)
        end
      end

      def redact_open_database(db, redacted_columns)
        tables = db.execute("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
          .map { |row| row[0] }

        # One transaction, or every UPDATE commits and syncs on its own. A
        # virtual table keeps per-row commits, because what its module stores
        # can depend on where they fall. On an error, close discards the
        # transaction; a ROLLBACK here could fail and hide that error.
        batch = db.get_first_value("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND rootpage = 0").zero?
        db.execute("BEGIN") if batch

        sha = Digest::SHA256.new
        tables.each do |table|
          next if table == "schema_migrations" || table == "ar_internal_metadata"

          if table == "instant_record_sync_metadata"
            redact_sync_metadata(db, table, redacted_columns, sha)
          elsif table == "instant_record_outbox"
            redact_outbox_table(db, table, redacted_columns, sha)
          else
            redact_user_table(db, table, redacted_columns, sha)
          end
        end

        db.execute("COMMIT") if batch
        db.execute("VACUUM")
      end

      def quote_ident(name)
        %("#{name.to_s.gsub('"', '""')}")
      end

      def redact_sync_metadata(db, table, redacted_columns, sha)
        quoted_table = quote_ident(table)
        rows = db.execute("SELECT key, value FROM #{quoted_table}")
        return if rows.empty?

        upd = nil
        redacted = false
        prefix, kind = hint_info("identity")
        begin
          rows.each do |key, value|
            next unless key == "identity" && value && !value.empty?

            upd ||= db.prepare("UPDATE #{quoted_table} SET value = ? WHERE key = ?")
            upd.bind_param(1, pseudonymize_fast(sha, prefix, kind, value))
            upd.bind_param(2, key)
            upd.step
            upd.reset!
            redacted = true
          end
        ensure
          upd&.close
        end

        redacted_columns[table] = ((redacted_columns[table] || []) | ["identity"]).sort if redacted
      end

      def redact_outbox_table(db, table, redacted_columns, sha)
        quoted_table = quote_ident(table)
        rows = db.execute("SELECT id, record_type, changes_payload FROM #{quoted_table}")
        return if rows.empty?

        upd = nil
        redacted_any = false
        begin
          rows.each do |id, record_type, payload|
            next if payload.nil? || payload.empty?

            begin
              parsed = JSON.parse(payload)
              redacted =
                if parsed.is_a?(Hash)
                  table_name = resolve_table_name(record_type || "*")
                  redact_attributes_for_table(table_name, pii_cache_for(table_name), parsed, sha)
                else
                  parsed
                end
              serialized = JSON.generate(redacted)
              next if serialized == payload

              upd ||= db.prepare("UPDATE #{quoted_table} SET changes_payload = ? WHERE id = ?")
              upd.bind_param(1, serialized)
              upd.bind_param(2, id)
              upd.step
              upd.reset!
              redacted_any = true
            rescue JSON::ParserError
              next
            end
          end
        ensure
          upd&.close
        end

        redacted_columns[table] = ((redacted_columns[table] || []) | ["changes_payload"]).sort if redacted_any
      end

      def redact_user_table(db, table, redacted_columns, sha)
        quoted_table = quote_ident(table)
        cols = db.execute("PRAGMA table_info(#{quoted_table})").map { |col| col[1] }
        pii_cols = cols.select { |col| pii_column?(table, col) }
        return if pii_cols.empty?

        select_cols = pii_cols.map { |c| quote_ident(c) }.join(", ")
        rows = db.execute("SELECT rowid AS __ir_rowid, #{select_cols} FROM #{quoted_table}")

        unless rows.empty?
          set_clause = pii_cols.map { |c| "#{quote_ident(c)} = ?" }.join(", ")
          prefixes = pii_cols.map { |c| hint_info(c)[0] }
          kinds = pii_cols.map { |c| hint_info(c)[1] }
          col_count = pii_cols.length

          upd = db.prepare("UPDATE #{quoted_table} SET #{set_clause} WHERE rowid = ?")
          begin
            rows.each do |row|
              i = 0
              while i < col_count
                val = row[i + 1]
                if val.nil? || val == ""
                  upd.bind_param(i + 1, val)
                else
                  upd.bind_param(i + 1, pseudonymize_fast(sha, prefixes[i], kinds[i], val))
                end
                i += 1
              end
              upd.bind_param(col_count + 1, row[0])
              upd.step
              upd.reset!
            end
          ensure
            upd.close
          end
        end

        redacted_columns[table] = pii_cols.sort
      end

      def redact_attributes_for_table(table, table_cache, attrs, sha)
        out = {}
        attrs.each do |key, value|
          if value.nil?
            out[key] = nil
            next
          end

          field = key.is_a?(String) ? key : key.to_s
          pii = table_cache[field]
          if pii.nil?
            pii = compute_pii_column?(table, field)
            table_cache.clear if table_cache.size >= CACHE_LIMIT
            table_cache[field] = pii
          end

          out[key] =
            if pii
              prefix, kind = hint_info(field)
              if value.is_a?(Array)
                value.map { |v| v.nil? || v == "" ? v : pseudonymize_fast(sha, prefix, kind, v) }
              elsif value.is_a?(Hash)
                pseudonymize_fast(sha, prefix, kind, JSON.generate(value))
              elsif value == ""
                value
              else
                pseudonymize_fast(sha, prefix, kind, value)
              end
            elsif value.is_a?(String)
              if value.include?("@")
                stripped = value.strip
                if EMAIL_VALUE_RE.match?(stripped)
                  pseudonymize_fast(sha, @email_hint_prefix, :email, stripped)
                else
                  value
                end
              else
                value
              end
            elsif value.is_a?(Hash)
              redact_attributes_for_table(table, table_cache, value, sha)
            elsif value.is_a?(Array)
              value.map { |item| item.is_a?(Hash) ? redact_attributes_for_table(table, table_cache, item, sha) : item }
            else
              value
            end
        end
        out
      end

      def pii_cache_for(table)
        cache = @pii_cache[table]
        return cache if cache

        @pii_cache.clear if @pii_cache.size >= CACHE_LIMIT
        @pii_cache[table] = {}
      end

      def compute_pii_column?(table, column_name)
        col = column_name.to_s.downcase
        return false if col.empty?

        safe_for_table = @explicit_safe[table]
        return false if (safe_for_table && safe_for_table[col]) || (@explicit_safe_wildcard && @explicit_safe_wildcard[col])

        pii_for_table = @explicit_pii[table]
        return true if (pii_for_table && pii_for_table[col]) || (@explicit_pii_wildcard && @explicit_pii_wildcard[col])
        return true if GOV_ID_RE.match?(col)
        return false if STRUCTURAL_SAFE_SET[col] || col.end_with?("_id", "_at")

        DEFAULT_PII_PATTERN.match?(col)
      end

      def hint_info(hint)
        cached = @hint_cache[hint]
        return cached if cached

        lower = hint.to_s.downcase
        kind =
          if lower.include?("email")
            :email
          elsif lower.include?("phone") || lower.include?("tel") || lower.include?("mobile")
            :phone
          else
            :generic
          end
        info = ["#{@salt}:#{hint}:".freeze, kind].freeze
        if hint.is_a?(String) || hint.is_a?(Symbol)
          @hint_cache.clear if @hint_cache.size >= CACHE_LIMIT
          @hint_cache[hint] = info
        end
        info
      end

      def pseudonymize_fast(sha, prefix, kind, value)
        text = value.is_a?(String) ? value : value.to_s
        sha.reset
        sha << prefix << text
        raw_digest = sha.digest!

        if kind == :email || (text.include?("@") && EMAIL_VALUE_RE.match?(text))
          "redacted-#{raw_digest.unpack1("H12")}@redacted.invalid"
        elsif kind == :phone
          "+1-555-#{raw_digest.unpack1("H4")}"
        else
          "[redacted:#{raw_digest.unpack1("H12")}]"
        end
      end

      def resolve_table_name(table_or_model)
        return "*" if table_or_model.nil?

        cached = @table_name_cache[table_or_model]
        return cached if cached

        str = table_or_model.to_s
        return "*" if str.empty?

        lower = str.downcase
        resolved =
          if @schema.key?(lower) || @explicit_pii.key?(lower) || @explicit_safe.key?(lower)
            lower
          else
            model_to_table(str)
          end

        if table_or_model.is_a?(String) || table_or_model.is_a?(Symbol)
          @table_name_cache.clear if @table_name_cache.size >= CACHE_LIMIT
          @table_name_cache[table_or_model] = resolved
        end
        resolved
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
          set = {}
          Array(cols).each { |c| set[c.to_s.downcase] = true }
          out[table.to_s.downcase] = set
        end
      end
    end
  end
end
