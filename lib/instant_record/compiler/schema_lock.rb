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
        instant_record_sync_notices
        instant_record_changes
        instant_record_applied_mutations
        ar_internal_metadata
        schema_migrations
      ].freeze

      INTERNAL_TABLE_SET = INTERNAL_TABLES.to_set.freeze
      SEED_NOW = "2026-11-20T00:00:00.000000Z"
      SYNC_METADATA_INSERT_SQL = "INSERT OR REPLACE INTO instant_record_sync_metadata (key, value, created_at, updated_at) VALUES (?, ?, ?, ?)"
      OUTBOX_INSERT_SQL = "INSERT INTO instant_record_outbox (id, record_type, record_id, operation, changes_payload, base_version, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"

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

      OUTBOX_TABLE_PATTERN = /CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?["`]?instant_record_outbox["`]?\b/i
      SYNC_METADATA_TABLE_PATTERN = /CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?["`]?instant_record_sync_metadata["`]?\b/i

      OPAQUE_SQL_PATTERN = /;|--|\/\*|\b(?:SELECT|REFERENCES|FOREIGN|TRIGGER|VIEW|VIRTUAL|TEMP|TEMPORARY|ATTACH|DETACH|PRAGMA|WITH|DROP|DELETE|INSERT|REPLACE|REINDEX|VACUUM|ANALYZE|EXPLAIN)\b/i
      CREATE_TABLE_PATTERN = /\ACREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:["`]([^"`]+)["`]|([a-zA-Z_][a-zA-Z0-9_]*))\s*\(/i
      CREATE_INDEX_PATTERN = /\ACREATE\s+(?:UNIQUE\s+)?INDEX\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:["`][^"`]+["`]|[a-zA-Z_][a-zA-Z0-9_]*)\s+ON\s+(?:["`]([^"`]+)["`]|([a-zA-Z_][a-zA-Z0-9_]*))\s*\(/i
      ALTER_ADD_PATTERN = /\AALTER\s+TABLE\s+(?:["`]([^"`]+)["`]|([a-zA-Z_][a-zA-Z0-9_]*))\s+ADD\s+/i
      SIMPLE_UPDATE_PATTERN = /\AUPDATE\s+(?:["`]([^"`]+)["`]|([a-zA-Z_][a-zA-Z0-9_]*))\s+SET\s+/i
      UPDATE_JOIN_PATTERN = /\b(?:FROM|JOIN)\b/i

      SqlContext = Struct.new(:adapter, keyword_init: true) do
        def adapter!
          self.adapter ||= ActiveRecord::ConnectionAdapters::SQLite3Adapter.new({ adapter: "sqlite3", database: ":memory:" })
        end

        def close!
          adapter&.disconnect!
          self.adapter = nil
        end
      end

      ReplayPlan = Struct.new(
        :versions,
        :step_classifications,
        :last_opaque_index,
        :head_version,
        :head_schema,
        :model_index,
        :last_outbox_create,
        :last_sync_meta_create,
        :seed_cache,
        :context,
        keyword_init: true
      )

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
          report = Report.new(lock_path: lock_path || path(root), checks: [], replayed_versions: [])

          lock = check_lockfile(report)
          return report unless lock

          plan = check_plan(report, root: root, baseline: baseline, migration_paths: migration_paths)
          return report unless plan

          # A wrong schema version or baseline is reported, but does not stop the replay.
          check_schema_version(report, lock, plan)
          return report unless check_migration_history(report, lock, plan)

          replay_upgrade_ladder!(report, lock, index_models(models))
          report
        end

        private

        def add_check(report, name, status, detail)
          report.checks << Check.new(name: name, status: status, detail: detail)
        end

        def check_lockfile(report)
          target = report.lock_path
          unless File.file?(target)
            add_check(report, "lockfile", :error, "missing #{target} (run `bin/rails instant_record:schema:lock`)")
            return
          end

          lock = parse_lockfile(target)
          unless lock.is_a?(Hash) && lock["lockfile_version"] == LOCKFILE_VERSION && lock["versions"].is_a?(Array)
            add_check(report, "lockfile", :error, "invalid or unsupported lockfile format")
            return
          end

          add_check(report, "lockfile", :ok, "v#{lock['lockfile_version']} (#{lock['versions'].size} versions)")
          lock
        end

        def check_plan(report, **options)
          BrowserMigrations.plan(**options)
        rescue BuildError => e
          add_check(report, "migrations plan", :error, e.message)
          nil
        end

        def check_schema_version(report, lock, plan)
          if lock["schema_version"] != plan["version"]
            add_check(report, "schema version", :error,
              "lockfile is at #{lock['schema_version']}, db/schema.rb is at #{plan['version']} (run `bin/rails instant_record:schema:lock`)")
          elsif lock["baseline"] != plan["baseline"]
            add_check(report, "schema baseline", :error,
              "lockfile baseline #{lock['baseline'].inspect} differs from configured #{plan['baseline'].inspect}")
          else
            add_check(report, "schema version", :ok, plan["version"].to_s)
          end
        end

        def check_migration_history(report, lock, plan)
          drift_errors = compare_versions(plan, lock)
          drift_errors.each { |message| add_check(report, "migration history", :error, message) }
          return false if drift_errors.any?

          add_check(report, "migration history", :ok, "all #{lock['versions'].size} locked versions immutable and current")
          true
        end

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

        def replay_upgrade_ladder!(report, lock, model_index)
          versions = lock["versions"].sort_by { |entry| entry["version"].to_i }
          baseline_sql = Array(lock["baseline_schema_sql"])
          context = SqlContext.new
          step_classifications = versions.map { |entry| classify_statements(entry["statements"]) }
          last_opaque_index = step_classifications.rindex { |stmts| stmts.any? { |kind, _| kind == :opaque } } || -1

          head_schema, snapshots = check_fresh_head_schema(report, baseline_sql, versions, step_classifications, context)
          return if head_schema.nil? || versions.empty?

          plan = ReplayPlan.new(
            versions: versions,
            step_classifications: step_classifications,
            last_opaque_index: last_opaque_index,
            head_version: lock["schema_version"],
            head_schema: head_schema,
            model_index: model_index,
            last_outbox_create: last_matching_step_index(versions, OUTBOX_TABLE_PATTERN),
            last_sync_meta_create: last_matching_step_index(versions, SYNC_METADATA_TABLE_PATTERN),
            seed_cache: { templates: {}, rows: {} },
            context: context
          )

          # Replay from EVERY historical version V_i (plus baseline if present) up to HEAD.
          starting_points = []
          unless baseline_sql.empty?
            starting_points << {
              version: lock["baseline"],
              schema_sql: baseline_sql,
              remaining_count: versions.size,
              start_idx: -1,
              snapshot: snapshots[:baseline]
            }
          end
          versions.each_with_index do |entry, idx|
            starting_points << {
              version: entry["version"],
              schema_sql: Array(entry["schema_sql"]),
              remaining_count: versions.size - idx - 1,
              start_idx: idx,
              snapshot: snapshots[idx]
            }
          end

          starting_points.each do |start|
            report.replayed_versions << start[:version]
            check_replay(report, start, plan)
          end
        ensure
          context&.close!
        end

        # Reference HEAD schema built cleanly from start -> HEAD.
        def check_fresh_head_schema(report, baseline_sql, versions, step_classifications, context)
          snapshots = {}
          capture_snapshots = !versions.empty?
          head_schema = with_sqlite do |db|
            current_infos = {}
            current_col_sets = {}
            supports_serialize = db.respond_to?(:serialize) && db.respond_to?(:deserialize)
            data_free = baseline_sql.all? { |sql| schema_only_ddl?(classify_statement(sql)) }

            baseline_sql.each { |sql| execute_sql(db, sql) }
            if capture_snapshots && !baseline_sql.empty?
              snapshots[:baseline] = capture_full_snapshot(
                db,
                current_infos,
                current_col_sets,
                context,
                capture_bytes: supports_serialize && data_free
              )
            end

            versions.each_with_index do |entry, idx|
              statements = entry["statements"]
              apply_version_transactionally!(db, entry["version"], statements)
              next unless capture_snapshots

              classified = step_classifications[idx]
              data_free = false if classified.any? { |kind, _| kind == :opaque }

              if statements.empty? && idx > 0
                snapshots[idx] = snapshots[idx - 1]
              elsif statements.empty? && !baseline_sql.empty?
                snapshots[idx] = snapshots[:baseline]
              else
                snapshots[idx] = capture_step_snapshot(
                  db,
                  classified,
                  current_infos,
                  current_col_sets,
                  context,
                  capture_bytes: supports_serialize && data_free
                )
              end
            end
            verify_integrity!(db, context)
            if capture_snapshots && !versions.empty?
              snapshots[versions.size - 1][:col_sets]
            else
              introspect_tables(db, context)
            end
          end
          add_check(report, "fresh HEAD schema", :ok, "#{head_schema.size} table(s), PRAGMA integrity_check ok")
          [head_schema, snapshots]
        rescue StandardError => e
          add_check(report, "fresh HEAD schema", :error, e.message)
          [nil, nil]
        end

        def capture_full_snapshot(db, current_infos, current_col_sets, context, capture_bytes:)
          schema_sql, tables, has_other_objects = read_master_snapshot(db, context)
          refresh_all_table_infos!(db, tables, current_infos, current_col_sets, context)
          {
            schema_sql: schema_sql,
            tables: tables,
            has_other_objects: has_other_objects,
            table_infos: current_infos.dup,
            col_sets: current_col_sets.dup,
            bytes: (capture_bytes && !has_other_objects) ? db.serialize : nil
          }
        end

        def capture_step_snapshot(db, classified, current_infos, current_col_sets, context, capture_bytes:)
          schema_sql, tables, has_other_objects = read_master_snapshot(db, context)
          if classified.any? { |kind, _| kind == :opaque }
            refresh_all_table_infos!(db, tables, current_infos, current_col_sets, context)
          else
            touched = Set.new
            classified.each do |kind, tbl|
              touched << tbl if kind == :create_table || kind == :alter_add
            end
            unless touched.empty?
              tables.each do |table|
                next unless touched.include?(table.downcase)

                info = table_info(db, table, context)
                current_infos[table] = info
                current_col_sets[table] = info.to_set { |_cid, name| name.to_s }
              end
            end
          end
          {
            schema_sql: schema_sql,
            tables: tables,
            has_other_objects: has_other_objects,
            table_infos: current_infos.dup,
            col_sets: current_col_sets.dup,
            bytes: (capture_bytes && !has_other_objects) ? db.serialize : nil
          }
        end

        def schema_only_ddl?(classified)
          kind = classified[0]
          kind == :create_table || kind == :create_index || kind == :alter_add
        end

        def compute_required_tables(populated_tables, step_classifications, start_idx)
          required = populated_tables.dup
          range = (start_idx + 1)...step_classifications.size
          loop do
            grew = false
            range.each do |step_idx|
              classified = step_classifications[step_idx]
              next unless classified.any? { |_, tbl| required.include?(tbl) }

              classified.each do |_, tbl|
                grew = true if required.add?(tbl)
              end
            end
            break unless grew
          end
          required
        end

        def refresh_all_table_infos!(db, tables, current_infos, current_col_sets, context)
          current_infos.clear
          current_col_sets.clear
          tables.each do |table|
            info = table_info(db, table, context)
            current_infos[table] = info
            current_col_sets[table] = info.to_set { |_cid, name| name.to_s }
          end
        end

        def read_master_snapshot(db, context)
          rows = read_rows(
            db,
            "SELECT type, name, sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' ORDER BY type DESC, name ASC",
            context
          )
          schema_sql = []
          tables = []
          has_other_objects = false
          rows.each do |type, name, sql|
            schema_sql << sql
            if type == "table"
              tables << name
            elsif type != "index"
              has_other_objects = true
            end
          end
          tables.sort!
          [schema_sql, tables, has_other_objects]
        end

        def classify_statements(statements)
          Array(statements).map { |sql| classify_statement(sql) }
        end

        def classify_statement(sql)
          s = sql.to_s.strip.sub(/;\s*\z/, "")
          return [:opaque, nil] if s.empty? || OPAQUE_SQL_PATTERN.match?(s)

          if (m = CREATE_TABLE_PATTERN.match(s))
            [:create_table, (m[1] || m[2]).downcase]
          elsif (m = CREATE_INDEX_PATTERN.match(s))
            [:create_index, (m[1] || m[2]).downcase]
          elsif (m = ALTER_ADD_PATTERN.match(s))
            [:alter_add, (m[1] || m[2]).downcase]
          elsif (m = SIMPLE_UPDATE_PATTERN.match(s)) && !UPDATE_JOIN_PATTERN.match?(s)
            [:update, (m[1] || m[2]).downcase]
          else
            [:opaque, nil]
          end
        end

        def check_replay(report, start, plan)
          name = "replay #{start[:version]}"
          preserved = replay_to_head!(start, plan)
          add_check(report, name, :ok,
            "#{start[:remaining_count]} step(s) -> #{plan.head_version}, #{preserved} pending outbox row(s) preserved & compatible")
        rescue StandardError => e
          add_check(report, name, :error, e.message)
        end

        def replay_to_head!(start, plan)
          from_version = start[:version]
          start_idx = start[:start_idx]
          snapshot = start[:snapshot]
          exact_snapshot = snapshot && snapshot[:bytes] && !snapshot[:has_other_objects] && start[:schema_sql] == snapshot[:schema_sql]
          can_prune = exact_snapshot && plan.last_opaque_index <= start_idx
          context = plan.context

          with_sqlite do |db|
            if exact_snapshot
              db.deserialize(snapshot[:bytes])
              current_tables = ensure_gem_tables_from_snapshot!(
                db,
                snapshot[:tables],
                start_idx,
                plan.last_outbox_create,
                plan.last_sync_meta_create
              )
              seeded_ids, populated_tables = seed_rows_and_outbox!(
                db,
                from_version,
                plan.model_index,
                context,
                existing_tables: current_tables,
                cached_table_infos: snapshot[:table_infos],
                seed_cache: plan.seed_cache
              )
            else
              start[:schema_sql].each { |sql| execute_sql(db, sql) }
              ensure_gem_tables!(db, start_idx, plan.last_outbox_create, plan.last_sync_meta_create, context)
              seeded_ids, populated_tables = seed_rows_and_outbox!(db, from_version, plan.model_index, context, seed_cache: plan.seed_cache)
            end

            if can_prune
              required_tables = compute_required_tables(populated_tables, plan.step_classifications, start_idx)
              mutated_tables = Set.new

              ((start_idx + 1)...plan.versions.size).each do |step_idx|
                classified = plan.step_classifications[step_idx]
                next unless classified.any? { |_, tbl| required_tables.include?(tbl) }

                step = plan.versions[step_idx]
                apply_version_transactionally!(db, step["version"], step["statements"])
                classified.each do |kind, tbl|
                  mutated_tables << tbl if kind == :create_table || kind == :alter_add
                end
              end

              verify_integrity!(db, context)
              surviving = current_tables.include?("instant_record_outbox") ? read_outbox_rows(db, context) : []
              parsed_changes = verify_outbox_survival!(from_version, seeded_ids, surviving)

              upgraded_schema = {}
              plan.head_schema.each_key do |table|
                down = table.downcase
                upgraded_schema[table] =
                  if mutated_tables.include?(down)
                    table_info(db, table, context).to_set { |_cid, name| name.to_s }
                  elsif populated_tables.include?(down)
                    snapshot[:col_sets][table]
                  else
                    plan.head_schema[table]
                  end
              end
              verify_schema_parity!(from_version, plan.head_schema, upgraded_schema)
            else
              ((start_idx + 1)...plan.versions.size).each do |step_idx|
                step = plan.versions[step_idx]
                apply_version_transactionally!(db, step["version"], step["statements"])
              end

              verify_integrity!(db, context)
              surviving = table_exists?(db, "instant_record_outbox", context) ? read_outbox_rows(db, context) : []
              parsed_changes = verify_outbox_survival!(from_version, seeded_ids, surviving)
              verify_schema_parity!(from_version, plan.head_schema, introspect_tables(db, context))
            end

            verify_outbox_compatibility!(from_version, plan.head_version, surviving, parsed_changes, plan.head_schema, plan.model_index)

            seeded_ids.size
          end
        end

        def with_sqlite
          db = ::SQLite3::Database.new(":memory:")
          yield db
        ensure
          db&.close unless db&.closed?
        end

        def execute_sql(db, sql)
          db.execute_batch(sql)
        end

        def apply_version_transactionally!(db, version, statements)
          return if statements.empty?

          db.execute("BEGIN IMMEDIATE")
          begin
            statements.each { |sql| db.execute_batch(sql) }
            db.execute("COMMIT")
          rescue StandardError => e
            begin
              db.execute("ROLLBACK")
            rescue StandardError
            end
            raise BuildError, "migration #{version} failed inside transaction: #{e.message}"
          end
        end

        def snapshot_schema_sql(db, context = nil)
          read_rows(
            db,
            "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' ORDER BY type DESC, name ASC",
            context
          ).map(&:first)
        end

        def introspect_tables(db, context = nil)
          table_names(db, context).each_with_object({}) do |table, map|
            map[table] = table_info(db, table, context).to_set { |_cid, name| name.to_s }
          end
        end

        def table_names(db, context = nil)
          read_rows(db, "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name ASC", context).map(&:first)
        end

        # Rows of cid, name, type, notnull, dflt_value, pk.
        def table_info(db, table, context = nil)
          read_rows(db, "PRAGMA table_info(#{quote_table_name(table)})", context)
        end

        # Every replay reads the whole schema, so these reads skip Active Record.
        # It still words the error of one that fails. The read is not run again: the
        # first attempt can change what a second one sees.
        def read_rows(db, sql, context = nil)
          unless ActiveRecord.query_transformers.empty?
            sql = with_error_adapter(context) { |adapter| adapter.send(:preprocess_query, sql) } # Query log tags are part of some error texts.
          end
          begin
            db.prepare(sql) do |statement|
              rows = []
              while (row = statement.step)
                rows << row
              end
              rows
            end
          rescue StandardError => e
            raise with_error_adapter(context) { |adapter| adapter.send(:translate_exception_class, e, sql, []) }
          end
        end

        def with_error_adapter(context)
          return yield context.adapter! if context

          adapter = ActiveRecord::ConnectionAdapters::SQLite3Adapter.new({ adapter: "sqlite3", database: ":memory:" })
          yield adapter
        ensure
          adapter&.disconnect!
        end

        def quote_table_name(table)
          ActiveRecord::ConnectionAdapters::SQLite3Adapter.quote_table_name(table)
        end

        def quote_column_name(col)
          ActiveRecord::ConnectionAdapters::SQLite3Adapter.quote_column_name(col)
        end

        def table_exists?(db, name, context = nil)
          read_rows(db, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '#{::SQLite3::Database.quote(name)}'", context).any?
        end

        def last_matching_step_index(versions, pattern)
          idx = versions.rindex { |step| Array(step["statements"]).any? { |sql| pattern.match?(sql) } }
          idx || -1
        end

        def ensure_gem_tables_from_snapshot!(db, tables, start_idx, last_outbox_create, last_sync_meta_create)
          added = nil
          if last_outbox_create <= start_idx && !tables.include?("instant_record_outbox")
            execute_sql(db, OUTBOX_TABLE_DDL)
            (added ||= []) << "instant_record_outbox"
          end
          if last_sync_meta_create <= start_idx && !tables.include?("instant_record_sync_metadata")
            execute_sql(db, SYNC_METADATA_TABLE_DDL)
            (added ||= []) << "instant_record_sync_metadata"
          end
          added ? (tables + added).sort : tables
        end

        def ensure_gem_tables!(db, start_idx, last_outbox_create, last_sync_meta_create, context)
          if !table_exists?(db, "instant_record_outbox", context) && last_outbox_create <= start_idx
            execute_sql(db, OUTBOX_TABLE_DDL)
          end
          if !table_exists?(db, "instant_record_sync_metadata", context) && last_sync_meta_create <= start_idx
            execute_sql(db, SYNC_METADATA_TABLE_DDL)
          end
        end

        def verify_integrity!(db, context = nil)
          result = read_rows(db, "PRAGMA integrity_check", context).map(&:first)
          raise "SQLite PRAGMA integrity_check failed: #{result.join(', ')}" unless result == ["ok"]
        end

        def seed_rows_and_outbox!(db, version, model_index, context, existing_tables: nil, cached_table_infos: nil, seed_cache: nil)
          existing_tables ||= table_names(db, context)
          has_sync_meta = existing_tables.include?("instant_record_sync_metadata")
          has_outbox = existing_tables.include?("instant_record_outbox")

          seeded_ids = []
          populated_tables = Set.new
          outbox_stmt = nil

          db.execute("BEGIN")
          begin
            if has_sync_meta
              db.execute(
                SYNC_METADATA_INSERT_SQL,
                ["schema_version", format("%020d", version.to_i), SEED_NOW, SEED_NOW]
              )
              populated_tables << "instant_record_sync_metadata"
            end

            cache = cached_table_infos ? seed_cache : nil

            existing_tables.each_with_index do |table, idx|
              next if INTERNAL_TABLE_SET.include?(table)

              columns = cached_table_infos ? cached_table_infos[table] : table_info(db, table, context)
              next if columns.nil? || columns.empty?

              template = seed_template_for(table, columns, cache)
              values, id_val, changes_json = seed_row_for(template, table, idx, cache)
              db.execute(template[:insert_sql], values)
              populated_tables << table.downcase
              next unless has_outbox

              record_type = resolve_record_type(table, model_index)
              record_id = (id_val || "rec-#{version}-#{idx}").to_s
              mutation_id = "replay-#{version}-#{table}-create"

              outbox_stmt ||= db.prepare(OUTBOX_INSERT_SQL)
              outbox_stmt.execute!(mutation_id, record_type, record_id, "create", changes_json, 0, SEED_NOW, SEED_NOW)
              seeded_ids << mutation_id
            end

            populated_tables << "instant_record_outbox" if has_outbox && !seeded_ids.empty?
            db.execute("COMMIT")
          rescue StandardError
            begin
              db.execute("ROLLBACK")
            rescue StandardError
            end
            raise
          ensure
            outbox_stmt&.close unless outbox_stmt&.closed?
          end

          [seeded_ids, populated_tables]
        end

        def seed_template_for(table, columns, seed_cache)
          cache_key = columns.object_id
          if seed_cache && (cached = seed_cache[:templates][cache_key]) && cached[:table] == table
            return cached
          end

          specs = []
          quoted_cols = []
          columns.each_with_index do |(_cid, raw_name, raw_type, _notnull, dflt, raw_pk), col_idx|
            name = raw_name.to_s
            type = raw_type.to_s.downcase
            pk = raw_pk.to_i > 0
            quoted_cols << quote_column_name(name)

            kind, const_val =
              if name == "id" && !type.include?("int")
                [:str_id, nil]
              elsif pk && type.include?("int")
                [:int_pk, nil]
              elsif name == "sync_state"
                [:const, "pending"]
              elsif name == "server_version"
                [:const, 0]
              elsif name == "created_at" || name == "updated_at" || type.include?("datetime") || type.include?("timestamp")
                [:const, SEED_NOW]
              elsif type.include?("date")
                [:const, "2026-11-20"]
              elsif type.include?("bool")
                [:const, 0]
              elsif type.include?("int")
                [:const, dflt ? dflt.to_i : (col_idx + 1)]
              elsif type.include?("float") || type.include?("real") || type.include?("dec") || type.include?("num")
                [:const, 1.0]
              elsif type.include?("blob")
                [:const, "seed"]
              else
                [:str_col, "seed-#{table}-#{name}-"]
              end

            specs << [name, kind, const_val]
          end

          placeholders = Array.new(specs.size, "?").join(", ")
          template = {
            table: table,
            key: cache_key,
            specs: specs,
            insert_sql: "INSERT INTO #{quote_table_name(table)} (#{quoted_cols.join(', ')}) VALUES (#{placeholders})"
          }
          seed_cache[:templates][cache_key] = template if seed_cache
          template
        end

        def seed_row_for(template, table, idx, seed_cache)
          if seed_cache
            row_key = [template[:key], idx]
            if (cached = seed_cache[:rows][row_key])
              return cached
            end
          end

          specs = template[:specs]
          values = Array.new(specs.size)
          changes = {}
          id_val = nil

          specs.each_with_index do |(name, kind, const_val), i|
            val =
              case kind
              when :const then const_val
              when :str_id then "seed-#{table}-#{idx}"
              when :int_pk then idx + 1
              else "#{const_val}#{idx}"
              end
            values[i] = val
            id_val = val if name == "id"
            changes[name] = val unless name == "sync_state"
          end

          result = [values, id_val, JSON.generate(changes)]
          seed_cache[:rows][[template[:key], idx]] = result if seed_cache
          result
        end

        def read_outbox_rows(db, context)
          read_rows(
            db,
            "SELECT id, record_type, record_id, operation, changes_payload, base_version, created_at, updated_at FROM instant_record_outbox ORDER BY created_at, id",
            context
          )
        end

        def verify_outbox_survival!(from_version, seeded_ids, surviving)
          surviving_ids = surviving.map { |row| row[0].to_s }
          missing = seeded_ids - surviving_ids
          unless missing.empty?
            raise "upgrade from #{from_version} lost #{missing.size} pending OutboxMutation row(s): #{missing.join(', ')}"
          end

          surviving.map do |row|
            JSON.parse(row[4].to_s)
          rescue JSON::ParserError => e
            raise "upgrade from #{from_version} corrupted OutboxMutation #{row[0]} JSON: #{e.message}"
          end
        end

        def verify_schema_parity!(from_version, head_schema, upgraded_schema)
          head_schema.each do |table, expected_cols|
            actual_cols = upgraded_schema[table]
            next if actual_cols == expected_cols

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

        def verify_outbox_compatibility!(from_version, head_version, surviving, parsed_changes, head_schema, model_index)
          has_global_upcasters = !OutboxUpcaster.registry.empty?

          surviving.each_with_index do |row, idx|
            changes = parsed_changes[idx]
            next unless changes.is_a?(Hash)

            record_type = row[1]
            model = find_model(record_type, model_index)
            has_model_upcasters = model && model.respond_to?(:instant_record_outbox_upcasters) && !model.instant_record_outbox_upcasters.empty?

            if has_global_upcasters || has_model_upcasters
              mutation = {
                id: row[0],
                record_type: record_type,
                record_id: row[2],
                operation: row[3],
                base_version: row[5].to_i,
                schema_version: from_version,
                changes: changes
              }

              mutation, changes = OutboxUpcaster.apply_global(mutation, changes)
              record_type = mutation[:record_type]
              model = find_model(record_type, model_index)
              changes = OutboxUpcaster.apply_for_model(model, changes, mutation) if model
            end

            table_name =
              if model && model.respond_to?(:table_name) && head_schema.key?(model.table_name)
                model.table_name
              else
                rt_str = record_type.to_s
                guess = model_index[:guessed_tables][rt_str] ||= rt_str.tableize
                head_schema.key?(guess) ? guess : nil
              end
            next unless table_name

            head_cols = head_schema.fetch(table_name)
            unknown = nil
            changes.each_key do |k|
              ks = k.is_a?(String) ? k : k.to_s
              next if ks == "sync_state" || head_cols.include?(ks)

              (unknown ||= []) << ks
            end
            next unless unknown

            raise "pending OutboxMutation from schema #{from_version} for #{record_type} carries column(s) " \
                  "#{unknown.join(', ')} missing at HEAD #{head_version}. Add an upcast_outbox transform on #{record_type}."
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
          { by_name: by_name, by_table: by_table, guessed_names: {}, guessed_tables: {} }
        end

        def resolve_record_type(table, model_index)
          if (klass = model_index[:by_table][table]) && klass.name
            return klass.name
          end

          model_index[:guessed_names][table] ||= ActiveSupport::Inflector.classify(table)
        end

        def find_model(record_type, model_index)
          model_index[:by_name][record_type.to_s] || InstantRecord.synced_model(record_type)
        end
      end
    end
  end
end
