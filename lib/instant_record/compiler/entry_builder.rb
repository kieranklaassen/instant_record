require "fileutils"
require "json"
require_relative "../native"
require_relative "manifest"
require_relative "runner"

module InstantRecord
  class Compiler
    # Builds the reactor entry files (`main_wasm.rb` and `main_native.rb`) from
    # a shared bridge and boot template, driven by `instant_record.manifest.json`.
    module EntryBuilder
      BANNER = "\n\n# ── persistent reactor entry"
      MODEL_NAME_PATTERN = /\A[A-Z]\w*(?:::[A-Z]\w*)*\z/
      IDENTIFIER_PATTERN = /\A[a-z_][a-z0-9_]*\z/

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
          # Keep the page receipt in the same SQLite transaction as its records.
          def self.history
            input = JSON.parse(<<read:in>>)
            key = "history:" + input["key"].to_s
            response = input["response"].to_s
            if response.empty?
              mark = InstantRecord::SyncMetadata.get(key)
              result = { ok: !mark.nil?, applied: 0, has_more: mark == "more" }
            else
              page = JSON.parse(response)
              records = Array(page["records"])
              more = page["has_more"] == true
              InstantRecord::OutboxMutation.transaction do
                records.each { |record| InstantRecord::Client.apply_change(record) }
                InstantRecord::SyncMetadata.set(key, more ? "more" : "end")
              end
              result = { ok: true, applied: records.size, has_more: more }
            end
            <<write:out>>JSON.generate(result))
            0
          end

          def self.cursor
            key = InstantRecord::Client.identity_key
            <<write:out>>"cursor=" + InstantRecord::Client.cursor.to_s + " pending=" + InstantRecord::Client.pending_count.to_s + " bootstrap=" + (InstantRecord::Client.bootstrapped? ? "ready" : "needed") + " identity=" + (key.nil? ? "" : key))
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
        <<windows>>InstantRecord.sync(<<models>>)
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

      def coerce_manifest(manifest)
        return nil if manifest.nil?
        return manifest if manifest.is_a?(Manifest)
        return Manifest.new(manifest) if manifest.is_a?(Hash)
        return Manifest.read(manifest.to_s) if manifest.is_a?(String) || manifest.is_a?(Pathname)

        raise ArgumentError, "Unsupported manifest: #{manifest.inspect}"
      end

      def app_models(manifest: nil, models: nil)
        parsed = coerce_manifest(manifest)
        list =
          if parsed&.island?
            parsed.synced_model_names
          elsif parsed && parsed.synced_model_names.any?
            parsed.synced_model_names
          else
            Array(models)
          end
        if list.empty? || !list.all? { |name| name.is_a?(String) && MODEL_NAME_PATTERN.match?(name) }
          raise BuildError, "Declare at least one named model that includes InstantRecord::Syncable."
        end
        list
      end

      def model_declarations(manifest)
        parsed = coerce_manifest(manifest)
        return "" unless parsed

        lines = []
        parsed.models.each do |entry|
          name = entry["name"]
          next unless name.is_a?(String) && MODEL_NAME_PATTERN.match?(name)

          if (window = entry["sync_window"])
            limit = Integer(window["limit"].to_s, 10)
            partition_by = window["partition_by"]
            if partition_by && !partition_by.to_s.empty?
              raise BuildError, "Invalid sync_window partition_by #{partition_by.inspect} on #{name}" unless IDENTIFIER_PATTERN.match?(partition_by.to_s)

              lines << "#{name}.sync_window(limit: #{limit}, partition_by: :#{partition_by})\n"
            else
              lines << "#{name}.sync_window(limit: #{limit})\n"
            end
          end

          column = entry.dig("sync_scope", "column")
          if column && !column.to_s.empty?
            raise BuildError, "Invalid sync_scope column #{column.inspect} on #{name}" unless IDENTIFIER_PATTERN.match?(column.to_s)

            lines << "#{name}.sync_scope(:#{column})\n"
          end
        end
        lines.join
      end

      def migrations(demo:, plan:, previous:, applied: "")
        return "" if demo

        steps = ["if restored", "  previous = #{previous}"]
        migrations_map = plan.fetch("migrations", {})
        migrations_map.sort_by { |version, _| version.to_i }.each do |version, statements|
          steps << %(  if previous < "#{format('%020d', version.to_i)}")
          statements.each do |sql|
            literal = JSON.generate(sql)
              .gsub('#{', '\\#{')
              .gsub('#@', '\\#@')
              .gsub('#$', '\\#$')
            steps << "    Db.exec(#{literal})"
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

      def start(streaming:, comment:, models:, manifest: nil)
        declarations = model_declarations(manifest)
        flag = "#{comment}\nInstantRecord::Client.streaming = #{streaming ? 'true' : 'false'}"
        fill(START, { "windows" => declarations, "models" => models.join(", "), "streaming" => flag })
      end

      def write_wasm_entry(emit_dir:, demo: false, manifest: nil, models: nil, migration_plan:, pipeline_dir:)
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
            models: resolved_models,
            manifest: manifest
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

      def write_native_entry(tree_dir:, app_dir:, demo: false, manifest: nil, models: nil, migration_plan:)
        wasm_main = File.read(File.join(tree_dir, "main_wasm.rb"))
        unless wasm_main.scan(BANNER).length == 1
          raise BuildError, "main_wasm.rb has no entry to start from"
        end

        head = wasm_main[0...wasm_main.index(BANNER)]
        found = discover_screens(app_dir)
        cases = found.map { |name, cls| %(    when "#{name}" then #{cls}.new(params)\n) }.join
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
            models: resolved_models,
            manifest: manifest
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
