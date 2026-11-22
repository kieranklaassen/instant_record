require "active_record"
require "active_record/connection_adapters/sqlite3_adapter"
require "active_support/inflector"
require "digest"
require "fileutils"
require "json"
require "set"
require_relative "../outbox_upcaster"
require_relative "browser_migrations"
require_relative "runner"

module InstantRecord
  class Compiler
    # Committed schema lockfile (`db/instant_record_lock.json`) and upgrade-ladder
    # CI/doctor replay verifier.
    #
    # Records every published browser migration version's compiled SQLite DDL and
    # cumulative sqlite_master schema snapshot. Verification replays EVERY
    # historical schema version — populated with realistic rows AND pending
    # OutboxMutation rows — through every subsequent transactional migration step
    # up to HEAD, confirming SQLite integrity, outbox survival, final schema
    # parity, and outbox-to-HEAD attribute compatibility (via `upcast_outbox`).
    class SchemaLock
      LOCKFILE_VERSION = 1
      FILENAME = "db/instant_record_lock.json"

      INTERNAL_TABLES = %w[
        instant_record_outbox
        instant_record_sync_metadata
        instant_record_changes
        instant_record_applied_mutations
        ar_internal_metadata
        schema_migrations
      ].freeze

      OUTBOX_TABLE_DDL = <<~SQL.strip
        CREATE TABLE IF NOT EXISTS "instant_record_outbox" (
          "id" varchar NOT NULL PRIMARY KEY,
          "record_type" varchar NOT NULL,
          "record_id" varchar NOT NULL,
          "operation" varchar NOT NULL,
          "changes_payload" text,
          "base_version" integer DEFAULT 0 NOT NULL,
          "created_at" datetime(6) NOT NULL,
          "updated_at" datetime(6) NOT NULL
        )
      SQL

      SYNC_METADATA_TABLE_DDL = <<~SQL.strip
        CREATE TABLE IF NOT EXISTS "instant_record_sync_metadata" (
          "key" varchar NOT NULL PRIMARY KEY,
          "value" varchar,
          "created_at" datetime(6) NOT NULL,
          "updated_at" datetime(6) NOT NULL
        )
      SQL

      Check = Struct.new(:name, :status, :detail, keyword_init: true) do
        def ok? = status != :error
      end

      Report = Struct.new(:lock_path, :checks, :replayed_versions, keyword_init: true) do
        def ok? = checks.all?(&:ok?)

        def errors
          checks.reject(&:ok?).map { |c| "#{c.name}: #{c.detail}" }
        end

        def to_s
          lines = ["InstantRecord schema lock check — #{lock_path}"]
          checks.each do |check|
            badge = check.ok? ? "OK" : "ERROR"
            lines << format("  [%-8s] %-24s %s", badge, check.name, check.detail)
          end
          lines.join("\n")
        end
      end

      class << self
        def path(root)
          File.join(root.to_s, FILENAME)
        end

        def generate(root:, baseline: nil, migration_paths: nil, existing: nil)
          plan = BrowserMigrations.plan(root: root, baseline: baseline, migration_paths: migration_paths)
          validate_immutability!(plan, existing) if existing

          baseline_int = plan["baseline"]
          baseline_schema_sql = build_baseline_schema_sql(
            root: root,
            baseline: baseline_int,
            migration_paths: migration_paths,
            existing: existing
          )

          versions = []
          with_sqlite do |conn|
            baseline_schema_sql.each { |sql| execute_sql(conn, sql) }

            plan.fetch("migrations", {}).sort_by { |v, _| v.to_i }.each do |version_str, statements|
              version_int = version_str.to_i
              apply_version_transactionally!(conn, version_int, statements)
              versions << {
                "version" => version_int,
                "digest" => plan.fetch("history").fetch(version_str),
                "statements" => statements,
                "schema_sql" => snapshot_schema_sql(conn)
              }
            end
          end

          lock = {
            "lockfile_version" => LOCKFILE_VERSION,
            "schema_version" => plan["version"],
            "baseline" => baseline_int,
            "versions" => versions
          }
          lock["baseline_schema_sql"] = baseline_schema_sql unless baseline_schema_sql.empty?
          lock
        end

        def write!(root:, baseline: nil, migration_paths: nil, lock_path: nil, force: false)
          target = lock_path || path(root)
          existing = !force && File.file?(target) ? JSON.parse(File.read(target)) : nil
          lock = generate(root: root, baseline: baseline, migration_paths: migration_paths, existing: existing)
          FileUtils.mkdir_p(File.dirname(target))
          File.write(target, JSON.pretty_generate(lock) + "\n")
          lock
        end

        def verify(root:, baseline: nil, migration_paths: nil, models: nil, lock_path: nil)
          target = lock_path || path(root)
          checks = []
          replayed_versions = []

          unless File.file?(target)
            checks << Check.new(
              name: "lockfile",
              status: :error,
              detail: "missing #{target} (run `bin/rails instant_record:schema:lock`)"
            )
            return Report.new(lock_path: target, checks: checks, replayed_versions: replayed_versions)
          end

          lock = parse_lockfile(target)
          unless lock.is_a?(Hash) && lock["lockfile_version"] == LOCKFILE_VERSION && lock["versions"].is_a?(Array)
            checks << Check.new(name: "lockfile", status: :error, detail: "invalid or unsupported lockfile format")
            return Report.new(lock_path: target, checks: checks, replayed_versions: replayed_versions)
          end
          checks << Check.new(name: "lockfile", status: :ok, detail: "v#{lock['lockfile_version']} (#{lock['versions'].size} versions)")

          begin
            plan = BrowserMigrations.plan(root: root, baseline: baseline, migration_paths: migration_paths)
          rescue BuildError => e
            checks << Check.new(name: "migrations plan", status: :error, detail: e.message)
            return Report.new(lock_path: target, checks: checks, replayed_versions: replayed_versions)
          end

          if lock["schema_version"] != plan["version"]
            checks << Check.new(
              name: "schema version",
              status: :error,
              detail: "lockfile is at #{lock['schema_version']}, db/schema.rb is at #{plan['version']} (run `bin/rails instant_record:schema:lock`)"
            )
          elsif lock["baseline"] != plan["baseline"]
            checks << Check.new(
              name: "schema baseline",
              status: :error,
              detail: "lockfile baseline #{lock['baseline'].inspect} differs from configured #{plan['baseline'].inspect}"
            )
          else
            checks << Check.new(name: "schema version", status: :ok, detail: plan["version"].to_s)
          end

          drift_errors = compare_versions(plan, lock)
          if drift_errors.empty?
            checks << Check.new(name: "migration history", status: :ok, detail: "all #{lock['versions'].size} locked versions immutable and current")
          else
            drift_errors.each do |msg|
              checks << Check.new(name: "migration history", status: :error, detail: msg)
            end
            return Report.new(lock_path: target, checks: checks, replayed_versions: replayed_versions)
          end

          model_index = index_models(models)
          replay_upgrade_ladder!(lock, model_index, checks, replayed_versions)

          Report.new(lock_path: target, checks: checks, replayed_versions: replayed_versions)
        end

        private

        def parse_lockfile(path)
          JSON.parse(File.read(path))
        rescue JSON::ParserError
          nil
        end

        def validate_immutability!(plan, existing)
          baseline_int = plan["baseline"]
          current_migrations = plan.fetch("migrations", {})
          current_history = plan.fetch("history", {})

          Array(existing["versions"]).each do |entry|
            version_str = entry["version"].to_i.to_s
            next if baseline_int && entry["version"].to_i <= baseline_int

            unless current_migrations.key?(version_str)
              raise BuildError, "Published browser migration #{version_str} was removed from #{FILENAME}. Add a new migration instead."
            end

            if current_history[version_str] != entry["digest"] || current_migrations[version_str] != entry["statements"]
              raise BuildError, "Published browser migration #{version_str} changed from #{FILENAME}. Add a new migration instead."
            end
          end
        end

        def compare_versions(plan, lock)
          errors = []
          baseline_int = plan["baseline"]
          current_migrations = plan.fetch("migrations", {})
          current_history = plan.fetch("history", {})
          locked_by_version = lock["versions"].each_with_object({}) { |entry, map| map[entry["version"].to_i.to_s] = entry }

          locked_by_version.each do |version_str, entry|
            next if baseline_int && version_str.to_i <= baseline_int

            unless current_migrations.key?(version_str)
              errors << "published migration #{version_str} was deleted"
              next
            end

            expected_digest = Digest::SHA256.hexdigest(JSON.generate(entry["statements"]))
            if entry["digest"] != expected_digest
              errors << "lockfile digest mismatch for migration #{version_str}"
            elsif current_history[version_str] != entry["digest"] || current_migrations[version_str] != entry["statements"]
              errors << "published migration #{version_str} changed; add a new migration instead"
            end
          end

          current_migrations.each_key do |version_str|
            unless locked_by_version.key?(version_str)
              errors << "migration #{version_str} is not recorded in #{FILENAME} (run `bin/rails instant_record:schema:lock`)"
            end
          end

          errors
        end

        def build_baseline_schema_sql(root:, baseline:, migration_paths:, existing:)
          return [] if baseline.nil?

          if existing && existing["baseline"] == baseline && existing["baseline_schema_sql"].is_a?(Array) && !existing["baseline_schema_sql"].empty?
            return existing["baseline_schema_sql"]
          end

          # Compile migrations <= baseline from migration_paths if available so
          # post-baseline upgrades can replay against a real baseline schema.
          full_plan = BrowserMigrations.plan(root: root, baseline: nil, migration_paths: migration_paths)
          pre = full_plan.fetch("migrations", {}).select { |v, _| v.to_i <= baseline }
          return [] if pre.empty?

          with_sqlite do |conn|
            pre.sort_by { |v, _| v.to_i }.each do |v, stmts|
              apply_version_transactionally!(conn, v.to_i, stmts)
            end
            snapshot_schema_sql(conn)
          end
        rescue BuildError
          []
        end

        def replay_upgrade_ladder!(lock, model_index, checks, replayed_versions)
          versions = lock["versions"].sort_by { |entry| entry["version"].to_i }
          baseline_sql = Array(lock["baseline_schema_sql"])

          # Reference HEAD schema built cleanly from start -> HEAD.
          head_schema = nil
          begin
            with_sqlite do |conn|
              baseline_sql.each { |sql| execute_sql(conn, sql) }
              versions.each { |entry| apply_version_transactionally!(conn, entry["version"], entry["statements"]) }
              verify_integrity!(conn)
              head_schema = introspect_tables(conn)
            end
            checks << Check.new(
              name: "fresh HEAD schema",
              status: :ok,
              detail: "#{head_schema.size} table(s), PRAGMA integrity_check ok"
            )
          rescue StandardError => e
            checks << Check.new(name: "fresh HEAD schema", status: :error, detail: e.message)
            return
          end

          return if versions.empty?

          head_version = lock["schema_version"]

          # Replay from EVERY historical version V_i (plus baseline if present) up to HEAD.
          starting_points = []
          unless baseline_sql.empty?
            starting_points << { version: lock["baseline"], schema_sql: baseline_sql, next_index: 0 }
          end
          versions.each_with_index do |entry, idx|
            starting_points << { version: entry["version"], schema_sql: Array(entry["schema_sql"]), next_index: idx + 1 }
          end

          starting_points.each do |start|
            from_version = start[:version]
            remaining = versions[start[:next_index]..] || []
            replayed_versions << from_version

            begin
              seeded_ids = []
              with_sqlite do |conn|
                start[:schema_sql].each { |sql| execute_sql(conn, sql) }
                ensure_gem_tables!(conn, remaining)

                seeded = seed_rows_and_outbox!(conn, from_version, model_index)
                seeded_ids = seeded.map { |m| m[:id] }

                remaining.each do |step|
                  apply_version_transactionally!(conn, step["version"], step["statements"])
                end

                verify_integrity!(conn)
                surviving = table_exists?(conn, "instant_record_outbox") ? read_outbox_rows(conn) : []
                verify_outbox_survival!(from_version, seeded_ids, surviving)
                verify_schema_parity!(from_version, head_schema, introspect_tables(conn))
                verify_outbox_compatibility!(from_version, head_version, surviving, head_schema, model_index)
              end

              checks << Check.new(
                name: "replay #{from_version}",
                status: :ok,
                detail: "#{remaining.size} step(s) -> #{head_version}, #{seeded_ids.size} pending outbox row(s) preserved & compatible"
              )
            rescue StandardError => e
              checks << Check.new(
                name: "replay #{from_version}",
                status: :error,
                detail: e.message
              )
            end
          end
        end

        def with_sqlite
          conn = ActiveRecord::ConnectionAdapters::SQLite3Adapter.new({ adapter: "sqlite3", database: ":memory:" })
          yield conn
        ensure
          conn&.disconnect!
        end

        def execute_sql(conn, sql)
          conn.raw_connection.execute_batch(sql)
        end

        def apply_version_transactionally!(conn, version, statements)
          return if statements.empty?

          raw = conn.raw_connection
          raw.execute("BEGIN IMMEDIATE")
          begin
            statements.each { |sql| raw.execute_batch(sql) }
            raw.execute("COMMIT")
          rescue StandardError => e
            begin
              raw.execute("ROLLBACK")
            rescue StandardError
            end
            raise BuildError, "migration #{version} failed inside transaction: #{e.message}"
          end
        end

        def snapshot_schema_sql(conn)
          conn.select_values(
            "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' ORDER BY type DESC, name ASC"
          )
        end

        def introspect_tables(conn)
          tables = conn.select_values(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name ASC"
          )
          tables.each_with_object({}) do |table, map|
            cols = conn.select_all("PRAGMA table_info(#{conn.quote_table_name(table)})").map { |row| row["name"].to_s }
            map[table] = cols.to_set
          end
        end

        def table_exists?(conn, name)
          conn.select_value(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = #{conn.quote(name)}"
          ) == 1
        end

        def remaining_creates_table?(remaining, table_name)
          pattern = /CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?["`]?#{Regexp.escape(table_name)}["`]?\b/i
          remaining.any? { |step| Array(step["statements"]).any? { |sql| pattern.match?(sql) } }
        end

        def ensure_gem_tables!(conn, remaining)
          if !table_exists?(conn, "instant_record_outbox") && !remaining_creates_table?(remaining, "instant_record_outbox")
            execute_sql(conn, OUTBOX_TABLE_DDL)
          end
          if !table_exists?(conn, "instant_record_sync_metadata") && !remaining_creates_table?(remaining, "instant_record_sync_metadata")
            execute_sql(conn, SYNC_METADATA_TABLE_DDL)
          end
        end

        def verify_integrity!(conn)
          result = conn.select_values("PRAGMA integrity_check")
          raise "SQLite PRAGMA integrity_check failed: #{result.join(', ')}" unless result == ["ok"]
        end

        def seed_rows_and_outbox!(conn, version, model_index)
          now = "2026-11-20T00:00:00.000000Z"
          if table_exists?(conn, "instant_record_sync_metadata")
            conn.raw_connection.execute(
              "INSERT OR REPLACE INTO instant_record_sync_metadata (key, value, created_at, updated_at) VALUES (?, ?, ?, ?)",
              ["schema_version", format("%020d", version.to_i), now, now]
            )
          end

          has_outbox = table_exists?(conn, "instant_record_outbox")
          tables = conn.select_values(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name ASC"
          )

          seeded_outbox = []
          tables.each_with_index do |table, idx|
            next if INTERNAL_TABLES.include?(table)

            columns = conn.select_all("PRAGMA table_info(#{conn.quote_table_name(table)})")
            next if columns.empty?

            row_attrs = build_sample_row(columns, table, idx, now)
            insert_sample_row!(conn, table, row_attrs)
            next unless has_outbox

            record_type = resolve_record_type(table, model_index)
            record_id = (row_attrs["id"] || "rec-#{version}-#{idx}").to_s
            changes = row_attrs.reject { |k, _| k == "sync_state" }
            mutation_id = "replay-#{version}-#{table}-create"

            conn.raw_connection.execute(
              "INSERT INTO instant_record_outbox (id, record_type, record_id, operation, changes_payload, base_version, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
              [mutation_id, record_type, record_id, "create", JSON.generate(changes), 0, now, now]
            )
            seeded_outbox << { id: mutation_id, table: table, record_type: record_type }
          end

          seeded_outbox
        end

        def build_sample_row(columns, table, idx, now)
          attrs = {}
          columns.each_with_index do |col, col_idx|
            name = col["name"].to_s
            type = col["type"].to_s.downcase
            pk = col["pk"].to_i > 0
            dflt = col["dflt_value"]

            attrs[name] =
              if name == "id" && !type.include?("int")
                "seed-#{table}-#{idx}"
              elsif pk && type.include?("int")
                idx + 1
              elsif name == "sync_state"
                "pending"
              elsif name == "server_version"
                0
              elsif name == "created_at" || name == "updated_at" || type.include?("datetime") || type.include?("timestamp")
                now
              elsif type.include?("date")
                "2026-11-20"
              elsif type.include?("bool")
                0
              elsif type.include?("int")
                dflt ? dflt.to_i : (col_idx + 1)
              elsif type.include?("float") || type.include?("real") || type.include?("dec") || type.include?("num")
                1.0
              elsif type.include?("blob")
                "seed"
              else
                "seed-#{table}-#{name}-#{idx}"
              end
          end
          attrs
        end

        def insert_sample_row!(conn, table, row_attrs)
          cols = row_attrs.keys.map { |c| conn.quote_column_name(c) }.join(", ")
          placeholders = Array.new(row_attrs.size, "?").join(", ")
          conn.raw_connection.execute(
            "INSERT INTO #{conn.quote_table_name(table)} (#{cols}) VALUES (#{placeholders})",
            row_attrs.values
          )
        end

        def read_outbox_rows(conn)
          conn.select_all(
            "SELECT id, record_type, record_id, operation, changes_payload, base_version, created_at, updated_at FROM instant_record_outbox ORDER BY created_at, id"
          ).to_a
        end

        def verify_outbox_survival!(from_version, seeded_ids, surviving)
          surviving_ids = surviving.map { |row| row["id"].to_s }
          missing = seeded_ids - surviving_ids
          unless missing.empty?
            raise "upgrade from #{from_version} lost #{missing.size} pending OutboxMutation row(s): #{missing.join(', ')}"
          end

          surviving.each do |row|
            JSON.parse(row["changes_payload"].to_s)
          rescue JSON::ParserError => e
            raise "upgrade from #{from_version} corrupted OutboxMutation #{row['id']} JSON: #{e.message}"
          end
        end

        def verify_schema_parity!(from_version, head_schema, upgraded_schema)
          head_schema.each do |table, expected_cols|
            actual_cols = upgraded_schema[table]
            unless actual_cols
              raise "upgrade from #{from_version} is missing table #{table.inspect} present at HEAD"
            end

            missing_cols = expected_cols - actual_cols
            extra_cols = actual_cols - expected_cols
            if missing_cols.any? || extra_cols.any?
              details = []
              details << "missing columns: #{missing_cols.to_a.sort.join(', ')}" if missing_cols.any?
              details << "extra columns: #{extra_cols.to_a.sort.join(', ')}" if extra_cols.any?
              raise "upgrade from #{from_version} drifted on table #{table.inspect} (#{details.join('; ')})"
            end
          end
        end

        def verify_outbox_compatibility!(from_version, head_version, surviving, head_schema, model_index)
          surviving.each do |row|
            changes = JSON.parse(row["changes_payload"].to_s)
            next unless changes.is_a?(Hash)

            mutation = {
              id: row["id"],
              record_type: row["record_type"],
              record_id: row["record_id"],
              operation: row["operation"],
              base_version: row["base_version"].to_i,
              schema_version: from_version,
              changes: changes
            }

            mutation, changes = OutboxUpcaster.apply_global(mutation, changes)
            model = find_model(mutation[:record_type], model_index)
            changes = OutboxUpcaster.apply_for_model(model, changes, mutation) if model

            table_name =
              if model && model.respond_to?(:table_name) && head_schema.key?(model.table_name)
                model.table_name
              else
                guess = mutation[:record_type].to_s.tableize
                head_schema.key?(guess) ? guess : nil
              end
            next unless table_name

            head_cols = head_schema.fetch(table_name)
            unknown = changes.keys.map(&:to_s).reject { |k| k == "sync_state" || head_cols.include?(k) }
            next if unknown.empty?

            raise "pending OutboxMutation from schema #{from_version} for #{mutation[:record_type]} carries column(s) " \
                  "#{unknown.join(', ')} missing at HEAD #{head_version}. Add an upcast_outbox transform on #{mutation[:record_type]}."
          end
        end

        def index_models(models)
          by_name = {}
          by_table = {}
          Array(models).each do |item|
            klass = item.is_a?(String) ? item.safe_constantize : item
            next unless klass.is_a?(Class)

            by_name[klass.name] = klass if klass.name
            by_table[klass.table_name] = klass if klass.respond_to?(:table_name) && klass.table_name
          end
          { by_name: by_name, by_table: by_table }
        end

        def resolve_record_type(table, model_index)
          if (klass = model_index[:by_table][table]) && klass.name
            return klass.name
          end

          ActiveSupport::Inflector.classify(table)
        end

        def find_model(record_type, model_index)
          model_index[:by_name][record_type.to_s] || InstantRecord.synced_model(record_type)
        end
      end
    end
  end
end
