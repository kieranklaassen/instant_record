require "json"
require "pathname"
require "rbconfig"
require "time"
require_relative "compiler"
require_relative "testing/authoritative_server"
require_relative "testing/fault_network"
require_relative "testing/runtimes/base"
require_relative "testing/runtimes/cruby_runtime"
require_relative "testing/runtimes/wasm_runtime"
require_relative "testing/runtimes/native_runtime"
require_relative "testing/parity_suite"
require_relative "testing/chaos_simulator"

module InstantRecord
  # CI-ready headless dual-runtime parity and seeded chaos simulation harness.
  # Exercises CRuby (with Postgres or SQLite), compiled app.wasm (Node AppHost),
  # and compiled Native C ABI (Ruby Fiddle) against the same authoritative sync
  # server, strictly asserting empty WASI/native stderr and bit-for-bit convergence.
  module Testing
    INT32_MAX = 2_147_483_647
    INT32_MIN = -2_147_483_648

    Error = Class.new(StandardError)
    ParityMismatch = Class.new(Error)
    StderrError = Class.new(Error)
    ConvergenceError = Class.new(Error)

    Artifacts = Struct.new(:wasm_path, :native_lib_path, :toolchain_path, :web_node_modules, keyword_init: true) do
      def wasm_available?
        !wasm_path.nil? && File.file?(wasm_path) && !web_node_modules.nil? && File.directory?(web_node_modules)
      end

      def native_available?
        !native_lib_path.nil? && File.file?(native_lib_path)
      end
    end

    class << self
      def gem_root
        Compiler.gem_root
      end

      def shared_library_name
        Compiler::NativeBuild.shared_library_name
      end

      # Discover compiled Wasm and Native artifacts (and optionally compile them
      # on demand when build: true and a toolchain file is present).
      def resolve_artifacts(root: nil, wasm_path: nil, native_lib_path: nil, toolchain: nil, build: false)
        search_roots = [root, gem_root].compact.map { |p| Pathname(p).expand_path }.uniq
        toolchain_path = find_toolchain(toolchain, search_roots)

        if build && toolchain_path
          build_artifacts!(root: root, toolchain_path: toolchain_path)
        end

        resolved_wasm = find_wasm(wasm_path, search_roots)
        resolved_native = find_native_lib(native_lib_path, search_roots)
        resolved_modules = find_web_node_modules(toolchain_path, search_roots)

        Artifacts.new(
          wasm_path: resolved_wasm,
          native_lib_path: resolved_native,
          toolchain_path: toolchain_path,
          web_node_modules: resolved_modules
        )
      end

      def select_runtimes(requested: nil, artifacts:, require_compiled: false)
        wanted =
          if requested.nil? || requested.to_s.strip.empty?
            list = [:cruby]
            list << :wasm if artifacts.wasm_available? || require_compiled
            list << :native if artifacts.native_available? || require_compiled
            list
          else
            Array(requested).flat_map { |r| r.to_s.split(",") }.map { |r| r.strip.downcase.to_sym }.reject(&:empty?).uniq
          end

        unknown = wanted - %i[cruby wasm native]
        raise ArgumentError, "Unknown runtime(s): #{unknown.join(', ')}. Expected cruby, wasm, or native." unless unknown.empty?

        if wanted.include?(:wasm) && !artifacts.wasm_available?
          if require_compiled || requested
            raise Error, "Wasm runtime requested but app.wasm or WEB_NODE_MODULES is missing " \
              "(wasm=#{artifacts.wasm_path.inspect}, web_node_modules=#{artifacts.web_node_modules.inspect}). " \
              "Build with `rake compile` or pass WASM_PATH=..."
          end
          wanted.delete(:wasm)
        end

        if wanted.include?(:native) && !artifacts.native_available?
          if require_compiled || requested
            raise Error, "Native C ABI runtime requested but #{shared_library_name} is missing " \
              "(native=#{artifacts.native_lib_path.inspect}). " \
              "Build with `rake compile:native` or pass NATIVE_LIB_PATH=..."
          end
          wanted.delete(:native)
        end

        wanted
      end

      # Canonicalize a record attribute value so Postgres, SQLite, Wasm, and
      # Native values compare bit-for-bit deterministically.
      def canonical_value(column, value)
        return nil if value.nil?

        col = column.to_s
        if col.end_with?("_at")
          canonical_timestamp(value)
        elsif col == "server_version" || col == "word_count" || col == "revision"
          value.to_i
        elsif value == true || value == false
          value
        elsif value.is_a?(Integer)
          value
        else
          value.to_s.encode(Encoding::UTF_8)
        end
      end

      def canonical_timestamp(value)
        time =
          if value.is_a?(Time)
            value.utc
          else
            str = value.to_s.strip
            return nil if str.empty?

            # SQLite stores UTC timestamps without zone suffix ("YYYY-MM-DD HH:MM:SS.ffffff").
            if str.match?(/\A\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?\z/)
              Time.parse("#{str.tr(' ', 'T')}Z").utc
            else
              Time.parse(str).utc
            end
          end
        time.iso8601(InstantRecord::TIME_PRECISION)
      end

      def canonical_rows(rows, exclude_columns: %w[sync_state])
        excluded = Array(exclude_columns).map(&:to_s)
        Array(rows).map do |row|
          pairs = row.each_with_object({}) do |(key, val), acc|
            col = key.to_s
            next if excluded.include?(col)

            acc[col] = canonical_value(col, val)
          end
          pairs.sort.to_h
        end.sort_by { |row| row["id"].to_s }
      end

      def canonical_json(object)
        JSON.pretty_generate(deep_sort(object))
      end

      def verify_parity(
        rails_app: nil,
        root: nil,
        database_url: ENV["DATABASE_URL"],
        runtimes: ENV["RUNTIMES"],
        wasm_path: ENV["WASM_PATH"],
        native_lib_path: ENV["NATIVE_LIB_PATH"],
        toolchain: ENV["INSTANT_RECORD_TOOLCHAIN"],
        build: ENV["BUILD"] == "1",
        require_compiled: ENV["REQUIRE_COMPILED"] == "1",
        out: $stdout
      )
        artifacts = resolve_artifacts(
          root: root,
          wasm_path: wasm_path,
          native_lib_path: native_lib_path,
          toolchain: toolchain,
          build: build
        )
        selected = select_runtimes(requested: runtimes, artifacts: artifacts, require_compiled: require_compiled)

        suite = ParitySuite.new(
          runtimes: selected,
          artifacts: artifacts,
          rails_app: rails_app,
          database_url: database_url,
          out: out
        )
        suite.run
      end

      def run_chaos(
        seeds: nil,
        steps: ENV.fetch("STEPS", "60").to_i,
        clients: ENV.fetch("CLIENTS", "3").to_i,
        rails_app: nil,
        root: nil,
        database_url: ENV["DATABASE_URL"],
        runtimes: ENV["RUNTIMES"],
        wasm_path: ENV["WASM_PATH"],
        native_lib_path: ENV["NATIVE_LIB_PATH"],
        toolchain: ENV["INSTANT_RECORD_TOOLCHAIN"],
        build: ENV["BUILD"] == "1",
        require_compiled: ENV["REQUIRE_COMPILED"] == "1",
        out: $stdout
      )
        artifacts = resolve_artifacts(
          root: root,
          wasm_path: wasm_path,
          native_lib_path: native_lib_path,
          toolchain: toolchain,
          build: build
        )
        selected = select_runtimes(requested: runtimes, artifacts: artifacts, require_compiled: require_compiled)
        seed_list = resolve_seeds(seeds)

        reports = seed_list.map do |seed|
          sim = ChaosSimulator.new(
            seed: seed,
            steps: steps,
            client_count: clients,
            runtimes: selected,
            artifacts: artifacts,
            rails_app: rails_app,
            database_url: database_url,
            out: out
          )
          sim.run
        end
        reports
      end

      private

      def resolve_seeds(seeds)
        if seeds
          Array(seeds).map(&:to_i)
        elsif ENV["SEED"] && !ENV["SEED"].strip.empty?
          ENV["SEED"].split(",").map { |s| Integer(s.strip) }
        else
          count = ENV.fetch("SEEDS", "3").to_i
          base = 20261121
          Array.new([count, 1].max) { |i| base + i }
        end
      end

      def deep_sort(obj)
        case obj
        when Hash
          obj.keys.map(&:to_s).sort.each_with_object({}) do |key, acc|
            raw_key = obj.key?(key) ? key : key.to_sym
            acc[key] = deep_sort(obj[raw_key])
          end
        when Array
          obj.map { |v| deep_sort(v) }
        else
          obj
        end
      end

      def find_toolchain(explicit, search_roots)
        candidates = []
        candidates << explicit if explicit && !explicit.to_s.empty?
        search_roots.each do |base|
          candidates << base.join("config/instant_record_toolchain.env").to_s
          candidates << base.join("compiled/toolchain.env").to_s
        end
        home = ENV["HOME"]
        candidates << File.join(home, ".cache/instant-record-tools/toolchain.env") if home && !home.empty?
        candidates.find { |path| File.file?(path) }
      end

      def find_wasm(explicit, search_roots)
        return File.expand_path(explicit) if explicit && !explicit.to_s.empty?

        patterns = search_roots.flat_map do |base|
          [
            base.join("compiled/web/dist/app-*.wasm").to_s,
            base.join("tmp/instant_record/compiled/web/dist/app-*.wasm").to_s,
            base.join("public/instant_record_compiled/current/app-*.wasm").to_s
          ]
        end
        patterns.each do |glob|
          found = Dir.glob(glob).max_by { |path| File.mtime(path) }
          return File.expand_path(found) if found
        end
        nil
      end

      def find_native_lib(explicit, search_roots)
        return File.expand_path(explicit) if explicit && !explicit.to_s.empty?

        lib = shared_library_name
        search_roots.each do |base|
          [
            base.join("compiled/.build-native", lib),
            base.join("tmp/instant_record/compiled/.build-native", lib)
          ].each do |candidate|
            return candidate.to_s if candidate.file?
          end
        end
        nil
      end

      def find_web_node_modules(toolchain_path, search_roots)
        if toolchain_path && File.file?(toolchain_path)
          tc = Compiler::Toolchain.load(toolchain_path)
          configured = tc["WEB_NODE_MODULES"]
          return configured if configured && File.directory?(configured)
        end

        search_roots.each do |base|
          [
            base.join("compiled/web/node_modules"),
            base.join("tmp/instant_record/compiled/web/node_modules")
          ].each do |candidate|
            return candidate.to_s if candidate.directory?
          end
        end
        nil
      end

      def build_artifacts!(root:, toolchain_path:)
        if root && Pathname(root).realpath != gem_root
          models = InstantRecord.syncable_models.map(&:name)
          Compiler.build(root: root, models: models, toolchain: toolchain_path, endpoint: InstantRecord::DEFAULT_MOUNT_PATH)
          Compiler.build_native(root: root, models: models, toolchain: toolchain_path, endpoint: InstantRecord::DEFAULT_MOUNT_PATH)
        else
          Compiler.build_demo(toolchain: toolchain_path)
          Compiler.build_demo_native(toolchain: toolchain_path)
        end
      end
    end
  end
end
