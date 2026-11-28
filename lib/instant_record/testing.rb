require "json"
require "pathname"
require "rbconfig"
require "time"
require_relative "compiler"

module InstantRecord
  # CI-ready headless dual-runtime parity and seeded chaos simulation harness.
  # Exercises CRuby (with Postgres or SQLite), compiled app.wasm (Node AppHost),
  # and compiled Native C ABI (Ruby Fiddle) against the same authoritative sync
  # server, strictly asserting empty WASI/native stderr and bit-for-bit convergence.
  module Testing
    INT32_MAX = 2_147_483_647
    INT32_MIN = -2_147_483_648

    DEFAULT_MODELS = %w[Issue AuthNote].freeze
    DEFAULT_ENDPOINT = InstantRecord::DEFAULT_MOUNT_PATH
    BOOTSTRAP_ABORT_MODES = %i[network_drop server_503 truncated_body].freeze

    DEFAULT_EXCLUDE_COLUMNS = %w[sync_state].freeze
    DEFAULT_EXCLUDED_SET = { "sync_state" => true }.freeze
    ROW_KEY_MISSING = Object.new.freeze
    UTC_SUFFIX_Z = "Z".freeze
    ZERO_FRAC_SUFFIX = ".#{'0' * InstantRecord::TIME_PRECISION}Z".freeze
    ZERO_FRAC_PADS = Array.new(InstantRecord::TIME_PRECISION) { |n| "#{'0' * n}Z".freeze }.freeze
    SQLITE_UTC_FALLBACK_RE = /\A\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?\z/
    FAST_UTC_FIXED_RE = /\A\d{4}-(?:(?:0[13578]|1[02])-(?:0[1-9]|[12]\d|3[01])|(?:0[469]|11)-(?:0[1-9]|[12]\d|30)|02-(?:0[1-9]|1\d|2[0-8]))[ T](?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d\.\d{#{InstantRecord::TIME_PRECISION}}Z?\z/
    FAST_UTC_GENERAL_RE = /\A\d{4}-(?:(?:0[13578]|1[02])-(?:0[1-9]|[12]\d|3[01])|(?:0[469]|11)-(?:0[1-9]|[12]\d|30)|02-(?:0[1-9]|1\d|2[0-9]))[ Tt](?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?(?:[Zz]|[+-]00(?::?00)?)?\z/
    FAST_OFFSET_RE = /\A\d{4}-(?:(?:0[13578]|1[02])-(?:0[1-9]|[12]\d|3[01])|(?:0[469]|11)-(?:0[1-9]|[12]\d|30)|02-(?:0[1-9]|1\d|2[0-9]))[ Tt](?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?[+-](?:[01]\d|2[0-3]):?[0-5]\d\z/
    private_constant :DEFAULT_EXCLUDE_COLUMNS, :DEFAULT_EXCLUDED_SET, :ROW_KEY_MISSING,
                     :UTC_SUFFIX_Z, :ZERO_FRAC_SUFFIX, :ZERO_FRAC_PADS,
                     :SQLITE_UTC_FALLBACK_RE, :FAST_UTC_FIXED_RE, :FAST_UTC_GENERAL_RE,
                     :FAST_OFFSET_RE

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

        col = column.instance_of?(String) ? column : column.to_s
        if col.end_with?("_at")
          canonical_timestamp(value)
        elsif col == "server_version" || col == "word_count" || col == "revision"
          value.is_a?(Integer) ? value : value.to_i
        elsif value.instance_of?(String)
          value.encoding == Encoding::UTF_8 ? value : value.encode(Encoding::UTF_8)
        elsif value == true || value == false || value.is_a?(Integer)
          value
        else
          str = value.to_s
          str.encoding == Encoding::UTF_8 ? str : str.encode(Encoding::UTF_8)
        end
      end

      def canonical_timestamp(value)
        if value.is_a?(Time)
          time = value.instance_of?(Time) ? (value.utc? ? value : value.getutc) : value.utc
          return time.iso8601(InstantRecord::TIME_PRECISION)
        end

        str = value.instance_of?(String) ? value : value.to_s
        b0 = str.getbyte(0)
        return nil unless b0

        if b0 <= 32 || str.getbyte(-1) <= 32
          str = str.strip
          return nil if str.empty?
        end

        precision = InstantRecord::TIME_PRECISION
        fixed_len = 20 + precision

        # Ultra-fast path for valid non-Feb-29 SQLite and ISO-8601 UTC strings
        # already carrying TIME_PRECISION fractional digits.
        if FAST_UTC_FIXED_RE.match?(str)
          len = str.bytesize
          sep = str.getbyte(10)
          if len == fixed_len + 1 && sep == 84
            if str.encoding == Encoding::UTF_8 || str.encoding == Encoding::US_ASCII
              return str
            end
            out = str.dup
            out.force_encoding(Encoding::UTF_8)
            return out
          end

          out = str.dup
          out.force_encoding(Encoding::UTF_8) unless out.encoding == Encoding::UTF_8 || out.encoding == Encoding::US_ASCII
          out.setbyte(10, 84) unless sep == 84
          out << UTC_SUFFIX_Z if len == fixed_len
          return out
        end

        # General fast path for other valid UTC timestamps (varying fraction
        # lengths, Feb 29 leap years, lowercase t/z, and zero offsets).
        if FAST_UTC_GENERAL_RE.match?(str)
          formatted = format_fast_utc_timestamp(str, precision)
          return formatted if formatted
        elsif precision == 6 && FAST_OFFSET_RE.match?(str)
          formatted = format_fast_offset_timestamp(str, precision)
          return formatted if formatted
        end

        # SQLite stores UTC timestamps without zone suffix ("YYYY-MM-DD HH:MM:SS.ffffff").
        time =
          if SQLITE_UTC_FALLBACK_RE.match?(str)
            Time.parse("#{str.tr(' ', 'T')}Z").utc
          else
            Time.parse(str).utc
          end
        time.iso8601(precision)
      end

      def canonical_rows(rows, exclude_columns: DEFAULT_EXCLUDE_COLUMNS)
        row_list = rows.is_a?(Array) ? rows : Array(rows)
        return [] if row_list.empty?

        excluded_set =
          if exclude_columns.equal?(DEFAULT_EXCLUDE_COLUMNS)
            DEFAULT_EXCLUDED_SET
          else
            build_excluded_set(exclude_columns)
          end

        first_row = row_list[0]
        plan_raw_keys = nil
        plan_cols = nil
        plan_kinds = nil
        excluded_raw_keys = nil
        expected_size = 0

        if first_row.is_a?(Hash)
          plan = build_row_plan(first_row, excluded_set)
          if plan
            plan_raw_keys, plan_cols, plan_kinds, excluded_raw_keys = plan
            expected_size = first_row.size
          end
        end

        result = Array.new(row_list.size)
        sorted_by_id = true
        prev_id = nil
        idx = 0
        row_count = row_list.size

        if plan_raw_keys
          plan_len = plan_raw_keys.size
          excl_len = excluded_raw_keys.size
          single_excl_key = excl_len == 1 ? excluded_raw_keys[0] : nil

          while idx < row_count
            row = row_list[idx]
            out = nil

            if row.is_a?(Hash) && row.size == expected_size
              excl_ok =
                if excl_len == 0
                  true
                elsif single_excl_key
                  row.key?(single_excl_key)
                else
                  ok = true
                  ei = 0
                  while ei < excl_len
                    unless row.key?(excluded_raw_keys[ei])
                      ok = false
                      break
                    end
                    ei += 1
                  end
                  ok
                end

              if excl_ok
                out = {}
                j = 0
                while j < plan_len
                  val = row.fetch(plan_raw_keys[j], ROW_KEY_MISSING)
                  if val.equal?(ROW_KEY_MISSING)
                    out = nil
                    break
                  end

                  if val.nil?
                    out[plan_cols[j]] = nil
                  else
                    kind = plan_kinds[j]
                    if kind == 0
                      out[plan_cols[j]] =
                        if val.instance_of?(String)
                          val.encoding == Encoding::UTF_8 ? val : val.encode(Encoding::UTF_8)
                        elsif val == true || val == false || val.is_a?(Integer)
                          val
                        else
                          s = val.to_s
                          s.encoding == Encoding::UTF_8 ? s : s.encode(Encoding::UTF_8)
                        end
                    elsif kind == 1
                      out[plan_cols[j]] = canonical_timestamp(val)
                    else
                      out[plan_cols[j]] = val.is_a?(Integer) ? val : val.to_i
                    end
                  end
                  j += 1
                end
              end
            end

            out ||= canonicalize_row_general(row, excluded_set)
            result[idx] = out

            id_val = out["id"]
            id_str = id_val.instance_of?(String) ? id_val : id_val.to_s
            sorted_by_id = false if prev_id && prev_id > id_str
            prev_id = id_str
            idx += 1
          end
        else
          while idx < row_count
            out = canonicalize_row_general(row_list[idx], excluded_set)
            result[idx] = out

            id_val = out["id"]
            id_str = id_val.instance_of?(String) ? id_val : id_val.to_s
            sorted_by_id = false if prev_id && prev_id > id_str
            prev_id = id_str
            idx += 1
          end
        end

        result.sort_by! { |row| (id = row["id"]).instance_of?(String) ? id : id.to_s } unless sorted_by_id
        result
      end

      def canonical_json(object)
        JSON.pretty_generate(deep_sort(object))
      end

      def elapsed_ms(started)
        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
      end

      def build_drivers(runtime_names:, artifacts:, network:, server:, models: DEFAULT_MODELS)
        drivers = {}
        Array(runtime_names).map(&:to_sym).uniq.each do |sym|
          drivers[sym] =
            case sym
            when :cruby
              Runtimes::CRubyRuntime.new(network: network, server: server, model_names: models)
            when :wasm
              Runtimes::WasmRuntime.new(
                wasm_path: artifacts.wasm_path,
                web_node_modules: artifacts.web_node_modules,
                network: network
              )
            when :native
              Runtimes::NativeRuntime.new(
                lib_path: artifacts.native_lib_path,
                network: network
              )
            else
              raise ArgumentError, "Unknown runtime: #{sym.inspect}. Expected cruby, wasm, or native."
            end
        end
        drivers
      rescue StandardError
        close_drivers(drivers)
        raise
      end

      def close_drivers(drivers, server: nil)
        drivers&.each_value do |driver|
          driver&.close
        rescue StandardError
          nil
        end
        server&.close
      end

      def with_runtime_harness(runtime_names:, artifacts:, rails_app: nil, database_url: nil, models: DEFAULT_MODELS)
        server = AuthoritativeServer.build(rails_app: rails_app, database_url: database_url, models: models)
        network = FaultNetwork.new(server)
        drivers = build_drivers(
          runtime_names: runtime_names,
          artifacts: artifacts,
          network: network,
          server: server,
          models: models
        )
        yield server, network, drivers
      ensure
        close_drivers(drivers, server: server)
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
        artifacts, selected = prepare_runtimes(
          root: root,
          runtimes: runtimes,
          wasm_path: wasm_path,
          native_lib_path: native_lib_path,
          toolchain: toolchain,
          build: build,
          require_compiled: require_compiled
        )

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
        artifacts, selected = prepare_runtimes(
          root: root,
          runtimes: runtimes,
          wasm_path: wasm_path,
          native_lib_path: native_lib_path,
          toolchain: toolchain,
          build: build,
          require_compiled: require_compiled
        )
        seed_list = resolve_seeds(seeds)

        seed_list.map do |seed|
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
      end

      private

      def prepare_runtimes(root:, runtimes:, wasm_path:, native_lib_path:, toolchain:, build:, require_compiled:)
        artifacts = resolve_artifacts(
          root: root,
          wasm_path: wasm_path,
          native_lib_path: native_lib_path,
          toolchain: toolchain,
          build: build
        )
        selected = select_runtimes(requested: runtimes, artifacts: artifacts, require_compiled: require_compiled)
        [artifacts, selected]
      end

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

      def format_fast_utc_timestamp(str, precision)
        # Validate Feb 29 leap year; non-leap Feb 29 falls back to Time.parse.
        if str.getbyte(5) == 48 && str.getbyte(6) == 50 && str.getbyte(8) == 50 && str.getbyte(9) == 57
          year = (str.getbyte(0) - 48) * 1000 + (str.getbyte(1) - 48) * 100 +
                 (str.getbyte(2) - 48) * 10 + (str.getbyte(3) - 48)
          return nil unless year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        end

        len = str.bytesize
        sep = str.getbyte(10)
        pos = 19
        frac_len = 0

        if pos < len && str.getbyte(pos) == 46
          pos = 20
          while pos < len
            b = str.getbyte(pos)
            break if b < 48 || b > 57
            pos += 1
          end
          frac_len = pos - 20
        end

        # Lowercase 't' without a zone suffix is parsed in local time by Time.parse.
        return nil if pos == len && sep == 116

        if frac_len == 0
          out = str.byteslice(0, 19)
          out.force_encoding(Encoding::UTF_8) unless out.encoding == Encoding::UTF_8 || out.encoding == Encoding::US_ASCII
          out.setbyte(10, 84) unless sep == 84
          out << ZERO_FRAC_SUFFIX
        elsif frac_len >= precision
          out = str.byteslice(0, 20 + precision)
          out.force_encoding(Encoding::UTF_8) unless out.encoding == Encoding::UTF_8 || out.encoding == Encoding::US_ASCII
          out.setbyte(10, 84) unless sep == 84
          out << UTC_SUFFIX_Z
        else
          out = str.byteslice(0, 20 + frac_len)
          out.force_encoding(Encoding::UTF_8) unless out.encoding == Encoding::UTF_8 || out.encoding == Encoding::US_ASCII
          out.setbyte(10, 84) unless sep == 84
          out << ZERO_FRAC_PADS[precision - frac_len]
        end
      end

      def format_fast_offset_timestamp(str, precision)
        year = (str.getbyte(0) - 48) * 1000 + (str.getbyte(1) - 48) * 100 +
               (str.getbyte(2) - 48) * 10 + (str.getbyte(3) - 48)
        month = (str.getbyte(5) - 48) * 10 + (str.getbyte(6) - 48)
        day = (str.getbyte(8) - 48) * 10 + (str.getbyte(9) - 48)
        if month == 2 && day == 29
          return nil unless year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        end

        hour = (str.getbyte(11) - 48) * 10 + (str.getbyte(12) - 48)
        min = (str.getbyte(14) - 48) * 10 + (str.getbyte(15) - 48)
        sec = (str.getbyte(17) - 48) * 10 + (str.getbyte(18) - 48)

        len = str.bytesize
        pos = 19
        usec = 0
        if str.getbyte(pos) == 46
          pos = 20
          scale = 100_000
          while pos < len
            b = str.getbyte(pos)
            break if b < 48 || b > 57
            if scale > 0
              usec += (b - 48) * scale
              scale /= 10
            end
            pos += 1
          end
        end

        sign = str.getbyte(pos) == 43 ? 1 : -1
        off_h = (str.getbyte(pos + 1) - 48) * 10 + (str.getbyte(pos + 2) - 48)
        m_pos = str.getbyte(pos + 3) == 58 ? pos + 4 : pos + 3
        off_m = (str.getbyte(m_pos) - 48) * 10 + (str.getbyte(m_pos + 1) - 48)
        offset_sec = sign * (off_h * 3600 + off_m * 60)

        (Time.utc(year, month, day, hour, min, sec, usec) - offset_sec).iso8601(precision)
      end

      def build_excluded_set(exclude_columns)
        set = {}
        Array(exclude_columns).each { |col| set[col.instance_of?(String) ? col : col.to_s] = true }
        set
      end

      def build_row_plan(row, excluded_set)
        seen = {}
        included = []
        excluded_raw_keys = []

        row.each_key do |raw_key|
          col = raw_key.instance_of?(String) ? raw_key : raw_key.to_s
          return nil if seen.key?(col)

          seen[col] = true
          if excluded_set.key?(col)
            excluded_raw_keys << raw_key
          else
            kind =
              if col.end_with?("_at")
                1
              elsif col == "server_version" || col == "word_count" || col == "revision"
                2
              else
                0
              end
            included << [col, raw_key, kind]
          end
        end

        included.sort_by! { |entry| entry[0] }
        plan_cols = []
        plan_raw_keys = []
        plan_kinds = []
        included.each do |col, raw_key, kind|
          plan_cols << col
          plan_raw_keys << raw_key
          plan_kinds << kind
        end
        [plan_raw_keys, plan_cols, plan_kinds, excluded_raw_keys]
      end

      def canonicalize_row_general(row, excluded_set)
        pairs = {}
        sorted = true
        prev = nil

        row.each do |key, val|
          col = key.instance_of?(String) ? key : key.to_s
          next if excluded_set.key?(col)

          sorted = false if prev && prev >= col
          prev = col
          pairs[col] = canonical_value(col, val)
        end

        return pairs if sorted

        keys = pairs.keys
        keys.sort!
        out = {}
        i = 0
        len = keys.length
        while i < len
          k = keys[i]
          out[k] = pairs[k]
          i += 1
        end
        out
      end

      def deep_sort(obj)
        if obj.is_a?(Hash)
          return {} if obj.empty?

          keys = obj.keys
          if keys.all?(String)
            keys.sort!
            out = {}
            i = 0
            len = keys.size
            while i < len
              k = keys[i]
              v = obj[k]
              out[k] = (v.is_a?(Hash) || v.is_a?(Array)) ? deep_sort(v) : v
              i += 1
            end
            return out
          end

          keys = keys.map(&:to_s)
          keys.sort!
          out = {}
          i = 0
          len = keys.size
          while i < len
            key = keys[i]
            raw_key = obj.key?(key) ? key : key.to_sym
            v = obj[raw_key]
            out[key] = (v.is_a?(Hash) || v.is_a?(Array)) ? deep_sort(v) : v
            i += 1
          end
          out
        elsif obj.is_a?(Array)
          len = obj.size
          return [] if len == 0

          first = obj[0]
          if len > 1 && first.is_a?(Hash) && !first.empty? && !first.compare_by_identity?
            plan_keys = first.keys
            if plan_keys.all?(String)
              plan_keys.sort!
              klen = plan_keys.size
              out_arr = Array.new(len)
              idx = 0
              while idx < len
                el = obj[idx]
                if el.is_a?(Hash) && el.size == klen
                  h = {}
                  j = 0
                  while j < klen
                    k = plan_keys[j]
                    v = el.fetch(k, ROW_KEY_MISSING)
                    if v.equal?(ROW_KEY_MISSING)
                      h = nil
                      break
                    end
                    h[k] = (v.is_a?(Hash) || v.is_a?(Array)) ? deep_sort(v) : v
                    j += 1
                  end
                  out_arr[idx] = h || deep_sort(el)
                else
                  out_arr[idx] = (el.is_a?(Hash) || el.is_a?(Array)) ? deep_sort(el) : el
                end
                idx += 1
              end
              return out_arr
            end
          end

          obj.map { |v| (v.is_a?(Hash) || v.is_a?(Array)) ? deep_sort(v) : v }
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

require_relative "testing/authoritative_server"
require_relative "testing/fault_network"
require_relative "testing/runtimes/base"
require_relative "testing/runtimes/cruby_runtime"
require_relative "testing/runtimes/wasm_runtime"
require_relative "testing/runtimes/native_runtime"
require_relative "testing/parity_suite"
require_relative "testing/chaos_simulator"
