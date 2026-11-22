require "fileutils"
require "json"
require_relative "../native"
require_relative "runner"

module InstantRecord
  class Compiler
    # Builds the reactor entry files (`main_wasm.rb` and `main_native.rb`) from
    # a shared bridge and boot template.
    module EntryBuilder
      BANNER = "\n\n# ── persistent reactor entry"
      DEMO_MODELS = %w[Issue ChatUser Channel Message Note MailEntry AssistantChat AssistantTurn AuthNote].freeze
      DEMO_SYNC_WINDOWS = { "Message" => { limit: 50, partition_by: :channel_id } }.freeze
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
          def self.handle_request
            req = Tep::Parser.parse(<<read:in>>)
            res = Tep::Response.new
            Tep::APP.dispatch(req, res)
            out = +""
            out << res.status.to_s << "\n"
            res.headers.each { |name, value| out << name.to_s << ": " << value.to_s << "\n" }
            res.header_fields.each { |pair| out << pair[0].to_s << ": " << pair[1].to_s << "\n" }
            res.set_cookies.each { |cookie| out << "Set-Cookie: " << cookie.to_s << "\n" }
            out << "X-File-Path: " << res.file_path << "\n" if res.file_path.length > 0
            out << "\n" << res.body
            <<write:out>>out)
            0
          end

          # Capture the exact outgoing batch before the worker yields to browser requests.
          def self.sync_plan
            mutations = InstantRecord::Client.pending_mutations
            push = mutations.empty? ? "" : JSON.generate(InstantRecord::Client.mutations_payload(mutations))
            <<write:out>>JSON.generate({ push: push, bootstrap: !InstantRecord::Client.bootstrapped? }))
            0
          end

          def self.handle_sync
            endpoint = <<read:in>>.strip
            InstantRecord.config.endpoint = endpoint if endpoint.length > 0
            changed = InstantRecord::Client.sync_pass
            <<write:out>>(changed ? "changed" : "unchanged") + " pending=" + InstantRecord::Client.pending_count.to_s + " cursor=" + InstantRecord::Client.cursor.to_s)
            0
          end

          def self.handle_stream
            applied = InstantRecord::Client.consume_stream(<<read:in>>)
            # A batch can be the server's reset, after which there is no cursor to report.
            <<write:out>>"applied=" + applied.to_s + " cursor=" + InstantRecord::Client.cursor.to_s + " bootstrap=" + (InstantRecord::Client.bootstrapped? ? "ready" : "needed"))
            0
          end

          # History has its own keyset and must not advance the live change cursor.
          # Route through Client's durable SQLite history ledger so CRuby, WASM,
          # and Native share one contiguity model and eviction invalidates it.
          def self.history
            input = JSON.parse(<<read:in>>)
            result = InstantRecord::Client.handle_history(
              key: input["key"].to_s,
              response: input["response"].to_s
            )
            <<write:out>>JSON.generate(result))
            0
          end

          def self.cursor
            key = InstantRecord::Client.identity_key
            <<write:out>>"cursor=" + InstantRecord::Client.cursor.to_s + " pending=" + InstantRecord::Client.pending_count.to_s + " bootstrap=" + (InstantRecord::Client.bootstrapped? ? "ready" : "needed") + " identity=" + (key.nil? ? "" : key))
            0
          end

          # Staging branch diff: OutboxMutations recorded after `exclude_ids`.
          def self.branch_outbox
            raw = <<read:in>>.strip
            input = raw.empty? ? {} : JSON.parse(raw)
            summary = InstantRecord::Branch.summary(since_ids: Array(input["exclude_ids"]))
            <<write:out>>JSON.generate(summary))
            0
          end

          # Safely replay extracted staging branch OutboxMutations onto current `main`.
          def self.branch_replay
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
        SqliteAdapter.configure(db_path)
        ActiveRecord.adapter = SqliteAdapter
        <<pragmas>>Schema.statements.each { |sql| SqliteAdapter.execute_ddl(sql) } unless restored
        <<migrations>>
        # Earlier demos saved a cursor before Note was a synced model. Rehydrate once
        # on a model-set change, preserving all local rows and pending mutations.
        model_set = "<<model_set>>"
        if InstantRecord::SyncMetadata.get("compiled_models") != model_set
          Schema.statements.each { |sql| SqliteAdapter.execute_ddl(sql) } if restored
          InstantRecord::SyncMetadata.where(key: "cursor").delete_all if restored
          InstantRecord::SyncMetadata.set("compiled_models", model_set)
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
            NativeHost.ir_host_give("out", screen.json)
            0
          end

          # In: the same, with "action", the "args" the tapped element carried and
          # the "values" a form's fields held.
          def self.action
            input = JSON.parse(NativeHost.ir_host_take("in"))
            screen = NativeScreens.find(input["screen"].to_s, InstantRecord::Native::Screen.strings(input["params"]))
            screen.perform(input["action"].to_s, InstantRecord::Native::Screen.strings(input["args"]), InstantRecord::Native::Screen.strings(input["values"]))
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

      module_function

      def app_models(demo:, models:)
        return DEMO_MODELS if demo

        list = Array(models)
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

      def sync_windows_code(demo:, sync_windows:)
        resolved = sync_windows.nil? ? (demo ? DEMO_SYNC_WINDOWS : {}) : sync_windows
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
          steps << %(  if previous < "#{format('%020d', version.to_i)}")
          statements.each do |sql|
            steps << "    Db.exec(#{ruby_string_literal(sql)})"
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

      def bridge(name, read:, write:, entries: "")
        fill(BRIDGE, { "bridge" => name, "entries" => entries }, read: read, write: write)
      end

      def database(pragmas:, steps:, models:)
        lines = pragmas.map { |pragma| %(SqliteAdapter.execute_ddl("PRAGMA #{pragma}")\n) }.join
        fill(DATABASE, { "pragmas" => lines, "migrations" => steps, "model_set" => models.sort.join(",") })
      end

      def start(streaming:, comment:, demo:, models:, sync_windows: nil, endpoint: nil, mount_path: nil)
        cfg = config_code(endpoint: endpoint, mount_path: mount_path)
        windows = sync_windows_code(demo: demo, sync_windows: sync_windows)
        flag = "#{comment}\nInstantRecord::Client.streaming = #{streaming ? 'true' : 'false'}"
        fill(START, { "config" => cfg, "windows" => windows, "models" => models.join(", "), "streaming" => flag })
      end

      def write_wasm_entry(emit_dir:, demo:, models:, migration_plan:, pipeline_dir:, sync_windows: nil, endpoint: nil, mount_path: nil)
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
        resolved_models = app_models(demo: demo, models: models)
        entry = BANNER + " for wasm32-wasi (see EntryBuilder) ─────────\n" +
          PRELUDE +
          bridge(
            "WasmBridge",
            read: ->(name) { %(File.read("/host/#{name}")) },
            write: ->(name) { "File.write(\"/host/#{name}\", " }
          ) +
          "\ndb_path = Main.default_db_path\n" +
          database(
            pragmas: ["locking_mode = EXCLUSIVE", "journal_mode = MEMORY", "cache_size = -4000"],
            steps: migrations(demo: demo, plan: migration_plan, previous: 'File.read("/host/schema_version")'),
            models: resolved_models
          ) +
          start(
            streaming: true,
            comment: "# JS worker owns non-blocking inbound polling; Client#sync_pass handles bootstrap + outbox drain.",
            demo: demo,
            models: resolved_models,
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

      def write_native_entry(tree_dir:, app_dir:, demo:, models:, migration_plan:, sync_windows: nil, endpoint: nil, mount_path: nil)
        wasm_main = File.read(File.join(tree_dir, "main_wasm.rb"))
        unless wasm_main.scan(BANNER).length == 1
          raise BuildError, "main_wasm.rb has no entry to start from"
        end

        head = wasm_main[0...wasm_main.index(BANNER)]
        found = discover_screens(app_dir)
        cases = found.map { |name, cls| %(    when "#{name}" then #{cls}.new(params)\n) }.join
        resolved_models = app_models(demo: demo, models: models)
        previous = 'InstantRecord::SyncMetadata.get("schema_version").to_s'
        applied = 'InstantRecord::SyncMetadata.set("schema_version", "<<version>>")'
        db_body = database(
          pragmas: ["cache_size = -4000"],
          steps: migrations(demo: demo, plan: migration_plan, previous: previous, applied: applied),
          models: resolved_models
        )

        entry = BANNER + " for a native host (see EntryBuilder) ─────────\n" +
          PRELUDE +
          NATIVE_HOST +
          fill(NATIVE_SCREENS, { "cases" => cases }) +
          bridge(
            "NativeBridge",
            read: ->(name) { %(NativeHost.ir_host_take("#{name}")) },
            write: ->(name) { "NativeHost.ir_host_give(\"#{name}\", " },
            entries: NATIVE_ENTRIES
          ) +
          fill(NATIVE_DATABASE, { "database" => indent(db_body, "    ") }) +
          "\nNativeDatabase.open(Main.default_db_path)\n" +
          start(
            streaming: false,
            comment: "# A sync pass pulls through the host: Client#sync_pass handles bootstrap, outbox drain and the poll.",
            demo: demo,
            models: resolved_models,
            sync_windows: sync_windows,
            endpoint: endpoint,
            mount_path: mount_path
          )

        File.write(File.join(tree_dir, "main_native.rb"), head + entry)
        rewrite_native_client_host(tree_dir)
        found.map(&:first)
      end

      def rewrite_native_client_host(tree_dir)
        client_dir = File.join(tree_dir, "app/models/instant_record/client")
        seams = 0
        if File.directory?(client_dir)
          Dir.glob("**/*.rb", base: client_dir).sort.each do |rel|
            path = File.join(client_dir, rel)
            text = File.read(path)
            changed = text.gsub(/File\.read\("\/host\/(\w+)"\)/, 'NativeHost.ir_host_take("\1")')
            changed = changed.gsub(/File\.write\("\/host\/(\w+)", /, 'NativeHost.ir_host_give("\1", ')
            changed = changed.gsub(/File\.write\((?:[\w:]+::)?REQUEST, /, 'NativeHost.ir_host_give("request", ')
            changed = changed.gsub(/File\.read\((?:[\w:]+::)?RESPONSE\)/, 'NativeHost.ir_host_take("response")')
            File.write(path, changed) if changed != text
            seams += 1 if changed.include?("NativeHost.")
          end
        end
        unless seams == 2
          raise BuildError, "expected the transport and the notifier to reach the host, found #{seams} file(s)"
        end
      end

      def indent(text, by)
        text.lines.map { |line| line.strip.empty? ? line : "#{by}#{line}" }.join
      end
    end
  end
end
