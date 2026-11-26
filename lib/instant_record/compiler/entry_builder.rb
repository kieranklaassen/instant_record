require "fileutils"
require "json"
require_relative "../native"
require_relative "manifest"
require_relative "host_adapters"
require_relative "runner"
require_relative "sync_action_dispatch"

module InstantRecord
  class Compiler
    # Builds the reactor entry files (`main_wasm.rb` and `main_native.rb`) from
    # a shared bridge and boot template, driven by `instant_record.manifest.json`.
    module EntryBuilder
      BANNER = "\n\n# ── persistent reactor entry"
      MODEL_NAME_PATTERN = /\A[A-Z]\w*(?:::[A-Z]\w*)*\z/
      COLUMN_NAME_PATTERN = /\A[a-z_][a-z0-9_]*\z/

      PRELUDE = <<~'RUBY'

        class Hash
          def deep_stringify_keys
            result = {}
            each do |key, value|
              result[key.to_s] = value.is_a?(Hash) ? value.deep_stringify_keys : value
            end
            result
          end
        end
      RUBY

      # <<read:NAME>> and <<write:NAME>> are the host's two calls, filled per target.
      BRIDGE = <<~'RUBY'

        module <<bridge>>
          # On its own: Spinel inlines the blocks of handle_request into one C function,
          # where the return values of nested ensure frames no longer fit each other.
          def self.dispatch_capturing_changes(req, res)
            InstantRecord::Client.capture_local_changes do
              Tep::APP.dispatch(req, res)
            end
            nil
          end

          def self.handle_request
            InstantRecord::Client.clear_events
            req = Tep::Parser.parse(<<read:in>>)
            res = Tep::Response.new
            reads = InstantRecord::ReadTracker.track do
              <<bridge>>.dispatch_capturing_changes(req, res)
            end
            out = +""
            out << res.status.to_s << "\n"
            res.headers.each { |name, value| out << name.to_s << ": " << value.to_s << "\n" }
            res.header_fields.each { |pair| out << pair[0].to_s << ": " << pair[1].to_s << "\n" }
            res.set_cookies.each { |cookie| out << "Set-Cookie: " << cookie.to_s << "\n" }
            out << "X-File-Path: " << res.file_path << "\n" if res.file_path.length > 0
            reads_json = InstantRecord::ReadTracker.serialize(reads)
            out << "X-Instant-Record-Reads: " << reads_json << "\n" unless reads_json.empty?
            out << "\n" << res.body
            <<write:out>>out)
            0
          end

          # Capture the next bounded outgoing batch before the worker yields to browser requests.
          def self.sync_plan
            InstantRecord::Client.clear_events
            mutations = InstantRecord::Client.plan_drain
            push = mutations.empty? ? "" : JSON.generate(InstantRecord::Client.mutations_payload(mutations))
            headers = InstantRecord::Client.request_headers
            next_ms = InstantRecord::Client.next_release_ms
            plan = {
              push: push,
              mutation_ids: mutations.map { |m| m[:id] },
              bootstrap: !InstantRecord::Client.bootstrapped?,
              fingerprint: "<<shell_fingerprint>>"
            }
            plan[:headers] = headers unless headers.empty?
            plan[:next_release_ms] = next_ms unless next_ms.nil?
            <<write:out>>JSON.generate(plan))
            0
          end

          def self.handle_sync
            InstantRecord::Client.clear_events
            raw = <<read:in>>.strip
            if raw.start_with?("{")
              input = JSON.parse(raw)
              endpoint = input["endpoint"].to_s.strip
              InstantRecord.config.endpoint = endpoint if endpoint.length > 0
              outcome = InstantRecord::Client.apply_prepared_sync(
                push: input["push"],
                bootstrap: input["bootstrap"]
              )
              changed = outcome[:changed]
              suffix = " progressed=" + (outcome[:progressed] ? "1" : "0") +
                " failed=" + (outcome[:failed] ? "1" : "0") +
                " quarantined=" + outcome[:quarantined].to_s
            else
              InstantRecord.config.endpoint = raw if raw.length > 0
              changed = InstantRecord::Client.sync_pass
              suffix = ""
            end
            next_ms = InstantRecord::Client.next_release_ms
            out = (changed ? "changed" : "unchanged") +
              " pending=" + InstantRecord::Client.pending_count.to_s +
              " cursor=" + InstantRecord::Client.cursor.to_s +
              " held=" + InstantRecord::Client.held_count.to_s
            out += " next_release_ms=" + next_ms.to_s unless next_ms.nil?
            out += suffix
            <<write:out>>out)
            0
          ensure
            InstantRecord::Client.clear_planned_drain
          end

          def self.handle_stream
            InstantRecord::Client.clear_events
            applied = InstantRecord::Client.consume_stream(<<read:in>>)
            # A batch can be the server's reset, after which there is no cursor to report.
            <<write:out>>"applied=" + applied.to_s + " cursor=" + InstantRecord::Client.cursor.to_s + " bootstrap=" + (InstantRecord::Client.bootstrapped? ? "ready" : "needed"))
            0
          end

          # History has its own keyset and must not advance the live change cursor.
          # Route through Client's durable SQLite history ledger so CRuby, WASM,
          # and Native share one contiguity model and eviction invalidates it.
          def self.history
            InstantRecord::Client.clear_events
            input = JSON.parse(<<read:in>>)
            result = InstantRecord::Client.handle_history(
              key: input["key"].to_s,
              response: input["response"].to_s
            )
            <<write:out>>JSON.generate(result))
            0
          end

          def self.cursor
            InstantRecord::Client.clear_events
            key = InstantRecord::Client.identity_key
            next_ms = InstantRecord::Client.next_release_ms
            out = "cursor=" + InstantRecord::Client.cursor.to_s + " pending=" + InstantRecord::Client.pending_count.to_s + " bootstrap=" + (InstantRecord::Client.bootstrapped? ? "ready" : "needed") + " identity=" + (key.nil? ? "" : key) + " notices=" + InstantRecord::SyncNotice.active.count.to_s + " held=" + InstantRecord::Client.held_count.to_s
            out += " next_release_ms=" + next_ms.to_s unless next_ms.nil?
            <<write:out>>out)
            0
          end

          # List or resolve quarantined sync notices ("list", "retry", "fork", "dismiss").
          def self.notices
            InstantRecord::Client.clear_events
            raw = <<read:in>>.to_s.strip
            input = raw.empty? ? {} : JSON.parse(raw)
            action = input["action"].to_s
            action = "list" if action.empty?
            result =
              if action == "list"
                { "ok" => true, "notices" => InstantRecord::SyncNotice.active.recent.map { |n| n.as_notice } }
              else
                resolved = InstantRecord::SyncNotice.resolve(input["id"], action: action, overrides: input["overrides"])
                if action == "retry" || action == "fork"
                  InstantRecord::Client.unlisted_changes
                  InstantRecord::Client.notify_changed
                end
                resolved
              end
            <<write:out>>JSON.generate(result))
            0
          rescue StandardError => error
            <<write:out>>JSON.generate({ "ok" => false, "error" => error.message, "notices" => InstantRecord::SyncNotice.active.recent.map { |n| n.as_notice } }))
            0
          end

          # Extract pending outbox rows directly from SQLite so a drifted or
          # unmigratable database can be rebuilt cleanly without losing offline writes.
          def self.export_outbox
            InstantRecord::Client.clear_events
            rows = []
            begin
              SqliteAdapter.each_row("SELECT id, record_type, record_id, operation, changes_payload, base_version, created_at, updated_at FROM instant_record_outbox ORDER BY created_at, id") do |row|
                payload = row["changes_payload"]
                rows << {
                  "id" => row["id"].to_s,
                  "record_type" => row["record_type"].to_s,
                  "record_id" => row["record_id"].to_s,
                  "operation" => row["operation"].to_s,
                  "changes_payload" => payload.nil? ? "{}" : payload.to_s,
                  "base_version" => row["base_version"].to_s.to_i,
                  "created_at" => row["created_at"].to_s,
                  "updated_at" => row["updated_at"].to_s
                }
              end
            rescue StandardError
              rows = []
            end
            <<write:out>>JSON.generate(rows))
            0
          end

          # Re-insert preserved outbox rows into a freshly rebuilt database in
          # one atomic SQLite transaction, keeping original ids and order.
          def self.import_outbox
            InstantRecord::Client.clear_events
            rows = JSON.parse(<<read:in>>)
            inserted = 0
            Db.exec("BEGIN IMMEDIATE")
            begin
              rows.each do |row|
                payload = row["changes_payload"]
                sql = "INSERT OR IGNORE INTO instant_record_outbox " \
                  "(id, record_type, record_id, operation, changes_payload, base_version, created_at, updated_at) VALUES (" +
                  Db.escape_string(row["id"].to_s) + ", " +
                  Db.escape_string(row["record_type"].to_s) + ", " +
                  Db.escape_string(row["record_id"].to_s) + ", " +
                  Db.escape_string(row["operation"].to_s) + ", " +
                  Db.escape_string(payload.nil? ? "{}" : payload.to_s) + ", " +
                  row["base_version"].to_i.to_s + ", " +
                  Db.escape_string(row["created_at"].to_s) + ", " +
                  Db.escape_string(row["updated_at"].to_s) + ")"
                Db.exec(sql)
                inserted += 1
              end
              Db.exec("COMMIT")
            rescue StandardError
              begin
                Db.exec("ROLLBACK")
              rescue StandardError
              end
              raise
            end
            <<write:out>>JSON.generate({ imported: inserted }))
            0
          end

          # Staging branch diff: OutboxMutations recorded after `exclude_ids`.
          def self.branch_outbox
            InstantRecord::Client.clear_events
            raw = <<read:in>>.strip
            input = raw.empty? ? {} : JSON.parse(raw)
            summary = InstantRecord::Branch.summary(since_ids: Array(input["exclude_ids"]))
            <<write:out>>JSON.generate(summary))
            0
          end

          # Safely replay extracted staging branch OutboxMutations onto current `main`.
          def self.branch_replay
            InstantRecord::Client.clear_events
            raw = <<read:in>>.strip
            input = raw.empty? ? {} : JSON.parse(raw)
            conflict = input["conflict"].to_s
            conflict = "lww" if conflict.empty?
            result = InstantRecord::Branch.replay_mutations(Array(input["mutations"]), conflict: conflict)
            <<write:out>>JSON.generate(result))
            0
          end
        <<entries>>end
      RUBY

      DATABASE = <<~'RUBY'
        restored = File.exist?(db_path) && File.size(db_path) > 0
        recovery = <<recovery>>
        SqliteAdapter.configure(db_path)
        ActiveRecord.adapter = SqliteAdapter
        <<pragmas>>unless recovery
          Schema.statements.each { |sql| SqliteAdapter.execute_ddl(sql) } unless restored
        <<migrations>>
          # Earlier demos saved a cursor before Note was a synced model. Rehydrate once
          # on a model-set change, preserving all local rows and pending mutations.
          model_set = "<<model_set>>"
          if InstantRecord::SyncMetadata.get("compiled_models") != model_set
            Schema.statements.each { |sql| SqliteAdapter.execute_ddl(sql) } if restored
            InstantRecord::SyncMetadata.where(key: "cursor").delete_all if restored
            InstantRecord::SyncMetadata.set("compiled_models", model_set)
          end
        end
      RUBY

      START = <<~'RUBY'
        Tep::APP.name = Rails.application.global_id_app
        <<config>><<windows>>InstantRecord.sync(<<models>>)
        <<streaming>>
      RUBY

      NATIVE_HOST = <<~'RUBY'

        # The native host's side of the bridge (native_shim.c).
        module NativeHost
          ffi_func :ir_host_take, [:str], :str
          ffi_func :ir_host_give, [:str, :str], :void
        end
      RUBY

      NATIVE_ENTRIES = <<~'RUBY'

          # In: {"screen": name, "params": {...}}. Out: the screen as JSON.
          def self.render
            input = JSON.parse(NativeHost.ir_host_take("in"))
            screen = NativeScreens.find(input["screen"].to_s, InstantRecord::Native::Screen.strings(input["params"]))
            rendered = ""
            reads = InstantRecord::ReadTracker.track do
              rendered = screen.json
            end
            NativeHost.ir_host_give("reads", InstantRecord::ReadTracker.serialize(reads))
            NativeHost.ir_host_give("out", rendered)
            0
          end

          # In: the same, with "action", the "args" the tapped element carried and
          # the "values" a form's fields held.
          def self.action
            input = JSON.parse(NativeHost.ir_host_take("in"))
            screen = NativeScreens.find(input["screen"].to_s, InstantRecord::Native::Screen.strings(input["params"]))
            InstantRecord::Client.capture_local_changes do
              screen.perform(input["action"].to_s, InstantRecord::Native::Screen.strings(input["args"]), InstantRecord::Native::Screen.strings(input["values"]))
            end
            0
          end

          # In: the SQLite file to work in from here on. The one open before is closed.
          def self.open
            NativeDatabase.open(NativeHost.ir_host_take("in"))
            0
          end
      RUBY

      NATIVE_DATABASE = <<~'RUBY'

        module NativeDatabase
          # A file that will not open leaves the app in the one it had: the host is told of
          # the failure and its screens go on working.
          def self.open(db_path)
            if @opened
              previous = @path
              begin
                use(db_path)
              rescue StandardError => error
                use(previous)
                raise error
              end
            else
              use(db_path)
            end
            0
          end

          def self.use(db_path)
            Db.close if @opened
            @opened = true
            @path = db_path
        <<database>>    InstantRecord::Client.forget_database
            0
          end
        end
      RUBY

      NATIVE_SCREENS = <<~'RUBY'

        module NativeScreens
          def self.find(name, params)
            case name
        <<cases>>    else raise ArgumentError, "No screen named " + name
            end
          end
        end
      RUBY

      NATIVE_SCREENS_EMPTY = <<~'RUBY'

        module NativeScreens
          def self.find(name, _params)
            raise ArgumentError, "No screen named " + name
          end
        end
      RUBY

      module_function

      def coerce_manifest(manifest)
        return nil if manifest.nil?
        return manifest if manifest.is_a?(Manifest)
        return Manifest.new(manifest) if manifest.is_a?(Hash)
        return Manifest.read(manifest.to_s) if manifest.is_a?(String) || manifest.is_a?(Pathname)

        raise ArgumentError, "Unsupported manifest: #{manifest.inspect}"
      end

      def app_models(manifest: nil, models: nil)
        parsed = coerce_manifest(manifest)
        from_manifest = parsed && (parsed.island? || parsed.synced_model_names.any?)
        list = from_manifest ? parsed.synced_model_names : Array(models)
        if list.empty? || !list.all? { |name| name.is_a?(String) && MODEL_NAME_PATTERN.match?(name) }
          raise BuildError, "Declare at least one named model that includes InstantRecord::Syncable."
        end
        list
      end

      def ruby_string_literal(value)
        JSON.generate(value.to_s)
          .gsub('#{', '\\#{')
          .gsub('#@', '\\#@')
          .gsub('#$', '\\#$')
      end

      def sync_windows_code(demo: false, manifest: nil, sync_windows: nil)
        parsed = coerce_manifest(manifest)
        resolved = sync_windows || parsed&.sync_windows || {}
        resolved.sort_by { |name, _| name.to_s }.map do |model_name, spec|
          name = model_name.to_s
          unless MODEL_NAME_PATTERN.match?(name)
            raise BuildError, "Invalid sync_window model name: #{name.inspect}"
          end

          limit = spec[:limit] || spec["limit"]
          unless limit.is_a?(Integer) && limit.positive?
            raise BuildError, "Invalid sync_window limit for #{name}: #{limit.inspect}"
          end

          partition = spec[:partition_by] || spec["partition_by"]
          if partition && !partition.to_s.empty?
            col = partition.to_s
            unless COLUMN_NAME_PATTERN.match?(col)
              raise BuildError, "Invalid sync_window partition_by column for #{name}: #{col.inspect}"
            end
            "#{name}.sync_window(limit: #{limit}, partition_by: :#{col})\n"
          else
            "#{name}.sync_window(limit: #{limit})\n"
          end
        end.join
      end

      def sync_scopes_code(manifest:)
        parsed = coerce_manifest(manifest)
        return "" unless parsed

        parsed.models.filter_map do |entry|
          name = entry["name"]
          next unless name.is_a?(String) && MODEL_NAME_PATTERN.match?(name)

          column = entry.dig("sync_scope", "column")
          next unless column && !column.to_s.empty?

          unless COLUMN_NAME_PATTERN.match?(column.to_s)
            raise BuildError, "Invalid sync_scope column #{column.inspect} on #{name}"
          end
          "#{name}.sync_scope(:#{column})\n"
        end.join
      end

      def config_code(endpoint:, mount_path:)
        lines = []
        lines << "InstantRecord.config.endpoint = #{ruby_string_literal(endpoint)}\n" if endpoint && !endpoint.to_s.empty?
        lines << "InstantRecord.config.mount_path = #{ruby_string_literal(mount_path)}\n" if mount_path && !mount_path.to_s.empty?
        lines.join
      end

      def migrations(demo:, plan:, previous:, applied: "")
        return "" if demo

        steps = ["if restored", "  previous = #{previous}"]
        migrations_map = plan.fetch("migrations", {})
        migrations_map.sort_by { |version, _| version.to_i }.each do |version, statements|
          padded = format("%020d", version.to_i)
          steps << %(  if previous < "#{padded}")
          steps << indent(migration_transaction(statements), "    ").chomp if statements.any?
          unless applied.empty?
            steps << "    " + applied.gsub("<<version>>") { padded }
          end
          steps << "  end"
        end
        steps << "end"
        unless applied.empty?
          latest = [plan["version"].to_i, *migrations_map.keys.map(&:to_i)].max
          steps << applied.gsub("<<version>>") { format("%020d", latest) }
        end
        "\n#{steps.join("\n")}\n"
      end

      def migration_transaction(statements)
        runs = statements.map { |sql| "  Db.exec(#{ruby_string_literal(sql)})\n" }.join
        <<~RUBY
          Db.exec("BEGIN IMMEDIATE")
          begin
          #{runs}  Db.exec("COMMIT")
          rescue StandardError
            begin
              Db.exec("ROLLBACK")
            rescue StandardError
            end
            raise
          end
        RUBY
      end
      private_class_method :migration_transaction

      def fill(text, values, read: nil, write: nil)
        result = text.dup
        values.each do |name, value|
          result = result.gsub("<<#{name}>>") { value }
        end
        if read
          result = result.gsub(/<<read:(\w+)>>/) { read.call(Regexp.last_match(1)) }
          result = result.gsub(/<<write:(\w+)>>/) { write.call(Regexp.last_match(1)) }
        end
        if (left = result[/<<[\w:]+>>/])
          raise BuildError, "EntryBuilder: nothing filled #{left}"
        end
        result
      end

      def bridge(name, read:, write:, entries: "", shell_fingerprint: "")
        fill(BRIDGE, { "bridge" => name, "entries" => entries, "shell_fingerprint" => shell_fingerprint.to_s }, read: read, write: write)
      end

      def database(pragmas:, steps:, models:, recovery: "false")
        lines = pragmas.map { |pragma| %(SqliteAdapter.execute_ddl("PRAGMA #{pragma}")\n) }.join
        indented_steps = steps.empty? ? "" : indent(steps, "  ")
        fill(DATABASE, { "pragmas" => lines, "migrations" => indented_steps, "model_set" => models.sort.join(","), "recovery" => recovery })
      end

      def start(streaming:, comment:, models:, demo: false, manifest: nil, sync_windows: nil, endpoint: nil, mount_path: nil)
        cfg = config_code(endpoint: endpoint, mount_path: mount_path)
        declarations = sync_windows_code(demo: demo, manifest: manifest, sync_windows: sync_windows) + sync_scopes_code(manifest: manifest)
        flag = "#{comment}\nInstantRecord::Client.streaming = #{streaming ? 'true' : 'false'}"
        fill(START, { "config" => cfg, "windows" => declarations, "models" => models.join(", "), "streaming" => flag })
      end

      def write_wasm_entry(emit_dir:, demo: false, manifest: nil, models: nil, migration_plan:, pipeline_dir:, app_dir: nil, sync_windows: nil, endpoint: nil, mount_path: nil, shell_fingerprint: "")
        if demo
          FileUtils.cp(
            File.join(pipeline_dir, "sqlite_release.rb"),
            File.join(emit_dir, "app/models/release.rb")
          )
        end

        source = File.read(File.join(emit_dir, "main.rb"))
        marker = %(\nif ARGV.length > 0 && ARGV[0] == "sidekiq")
        cut = source.index(marker)
        raise BuildError, "Expected sidekiq marker in #{File.join(emit_dir, 'main.rb')}" unless cut

        head = source[0...cut]
        resolved_models = app_models(manifest: manifest, models: models)
        entry = BANNER + " for wasm32-wasi (see EntryBuilder) ─────────\n" +
          PRELUDE +
          sync_actions_module(app_dir) +
          bridge(
            "WasmBridge",
            read: ->(name) { %(File.read("/host/#{name}")) },
            write: ->(name) { "File.write(\"/host/#{name}\", " },
            shell_fingerprint: shell_fingerprint
          ) +
          "\ndb_path = Main.default_db_path\n" +
          database(
            pragmas: ["locking_mode = EXCLUSIVE", "journal_mode = MEMORY", "cache_size = -4000"],
            steps: migrations(demo: demo, plan: migration_plan, previous: 'File.read("/host/schema_version")'),
            models: resolved_models,
            recovery: 'File.exist?("/host/recovery") && File.read("/host/recovery") == "extract_outbox"'
          ) +
          start(
            streaming: true,
            comment: "# JS worker owns non-blocking inbound polling; Client#sync_pass handles bootstrap + outbox drain.",
            demo: demo,
            models: resolved_models,
            manifest: manifest,
            sync_windows: sync_windows,
            endpoint: endpoint,
            mount_path: mount_path
          )

        File.write(File.join(emit_dir, "main_wasm.rb"), head + entry)
      end

      def discover_screens(app_dir)
        folder = File.join(app_dir, "app/screens")
        return [] unless File.directory?(folder)

        Dir.glob("*_screen.rb", base: folder)
          .map { |file| file.delete_suffix("_screen.rb") }
          .sort
          .map { |name| [name, InstantRecord::Native.class_name(name)] }
      rescue ArgumentError => e
        raise BuildError, e.message
      end

      def native_screens_module(screens)
        return NATIVE_SCREENS_EMPTY if screens.empty?

        cases = screens.map { |name, class_name| %(    when "#{name}" then #{class_name}.new(params)\n) }.join
        fill(NATIVE_SCREENS, { "cases" => cases })
      end
      private_class_method :native_screens_module

      def write_native_entry(tree_dir:, app_dir:, demo: false, manifest: nil, models: nil, migration_plan:, sync_windows: nil, endpoint: nil, mount_path: nil, shell_fingerprint: "")
        wasm_main = File.read(File.join(tree_dir, "main_wasm.rb"))
        unless wasm_main.scan(BANNER).length == 1
          raise BuildError, "main_wasm.rb has no entry to start from"
        end

        head = wasm_main[0...wasm_main.index(BANNER)]
        found = discover_screens(app_dir)
        screens_block = native_screens_module(found)
        resolved_models = app_models(manifest: manifest, models: models)
        previous = 'InstantRecord::SyncMetadata.get("schema_version").to_s'
        applied = 'InstantRecord::SyncMetadata.set("schema_version", "<<version>>")'
        db_body = database(
          pragmas: ["cache_size = -4000"],
          steps: migrations(demo: demo, plan: migration_plan, previous: previous, applied: applied),
          models: resolved_models
        )

        entry = BANNER + " for a native host (see EntryBuilder) ─────────\n" +
          PRELUDE +
          sync_actions_module(app_dir) +
          NATIVE_HOST +
          screens_block +
          bridge(
            "NativeBridge",
            read: ->(name) { %(NativeHost.ir_host_take("#{name}")) },
            write: ->(name) { "NativeHost.ir_host_give(\"#{name}\", " },
            entries: NATIVE_ENTRIES,
            shell_fingerprint: shell_fingerprint
          ) +
          fill(NATIVE_DATABASE, { "database" => indent(db_body, "    ") }) +
          "\nNativeDatabase.open(Main.default_db_path)\n" +
          start(
            streaming: false,
            comment: "# A sync pass pulls through the host: Client#sync_pass handles bootstrap, outbox drain and the poll.",
            demo: demo,
            models: resolved_models,
            manifest: manifest,
            sync_windows: sync_windows,
            endpoint: endpoint,
            mount_path: mount_path
          )

        File.write(File.join(tree_dir, "main_native.rb"), head + entry)
        install_native_host_adapter(tree_dir)
        found.map(&:first)
      end

      def install_native_host_adapter(tree_dir)
        candidates = [
          File.join(tree_dir, "app/models/instant_record/host.rb"),
          File.join(tree_dir, "lib/instant_record/host.rb")
        ].select { |path| File.file?(path) }

        if candidates.empty?
          raise BuildError, "expected emitted InstantRecord::Host adapter in #{tree_dir}"
        end

        candidates.each do |path|
          File.write(path, HostAdapters::Native.host_source)
        end
      end

      def indent(text, by)
        text.lines.map { |line| line.strip.empty? ? line : "#{by}#{line}" }.join
      end
    end
  end
end
