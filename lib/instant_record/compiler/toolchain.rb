require "open3"
require "pathname"
require_relative "runner"

module InstantRecord
  class Compiler
    # Reads a toolchain.env file (KEY=VALUE lines with $VAR/${VAR} expansion)
    # and validates that the required external tools are present before a build.
    class Toolchain
      VAR_REF = /\$(?:\{([A-Za-z_]\w*)\}|([A-Za-z_]\w*))/
      STATUS_BADGES = {
        ok: "OK",
        optional: "OPTIONAL",
        error: "ERROR",
        fail: "FAIL"
      }.freeze
      private_constant :VAR_REF, :STATUS_BADGES

      Check = Struct.new(:name, :status, :detail, keyword_init: true) do
        def ok? = status == :ok || status == :optional
      end

      Report = Struct.new(:target, :path, :checks, :lint, keyword_init: true) do
        def ok? = checks.all?(&:ok?) && (lint.nil? || lint.ok?)

        def with_lint(lint_result)
          lint_check =
            if lint_result.ok?
              Check.new(name: "static lint", status: :ok, detail: "0 issues across #{lint_result.files_checked} files")
            else
              Check.new(name: "static lint", status: :fail, detail: "#{lint_result.diagnostics.size} issue(s) across #{lint_result.files_checked} files")
            end
          Report.new(target: target, path: path, checks: checks + [lint_check], lint: lint_result)
        end

        def to_s
          lines = ["InstantRecord toolchain check (#{target}) — #{path}"]
          checks.each do |check|
            badge = STATUS_BADGES.fetch(check.status, "MISSING")
            lines << format("  [%-8s] %-18s %s", badge, check.name, check.detail)
          end
          if lint && !lint.ok?
            lint_text = lint.to_s
            unless lint_text.empty?
              lines << ""
              lines << lint_text
            end
          end
          lines.join("\n")
        end
      end

      attr_reader :path, :values

      def self.load(path)
        return path if path.is_a?(self)

        expanded = Pathname(path).expand_path
        raise ArgumentError, "Missing compiler toolchain file: #{expanded}" unless expanded.file?

        values = {}
        File.foreach(expanded) do |raw|
          line = raw.strip
          next if line.empty? || line.start_with?("#") || !line.include?("=")

          key, value = line.split("=", 2)
          key = key.strip
          next if key.empty?

          value = value.gsub(VAR_REF) { |match| values.fetch(Regexp.last_match(1) || Regexp.last_match(2), match) }
          values[key] = value
        end
        new(path: expanded.to_s, values: values)
      end

      def self.which(command, extra_paths: [])
        return nil if command.nil?

        cmd = command.to_s
        return nil if cmd.empty?

        if cmd.include?(File::SEPARATOR)
          return executable_file?(cmd) ? cmd : nil
        end

        search = Array(extra_paths) + ENV.fetch("PATH", "").split(File::PATH_SEPARATOR)
        search.each do |dir|
          next if dir.nil? || dir.empty?

          candidate = File.join(dir, cmd)
          return candidate if executable_file?(candidate)
        end
        nil
      end

      def self.executable_file?(path)
        File.file?(path) && File.executable?(path)
      end
      private_class_method :executable_file?

      def initialize(path:, values:)
        @path = path
        @values = values
      end

      def [](key)
        @values[key.to_s]
      end

      def fetch(key)
        value = @values[key.to_s]
        raise BuildError, "Missing #{key} in #{@path}" if value.nil? || value.empty?

        value
      end

      def join(key, *parts)
        File.join(fetch(key), *parts)
      end

      def doctor(target: :wasm, web_dir: nil)
        mode = target.nil? || target.to_s.empty? ? :wasm : target.to_sym
        target_specific = target_checks(mode, target: target, web_dir: web_dir)
        Report.new(target: mode, path: @path, checks: common_checks + target_specific)
      end

      private

      def common_checks
        [
          check_exec("spinel", optional_path("SPINEL_HOME", "bin/spinel"), "SPINEL_HOME/bin/spinel"),
          check_exec("spin", optional_path("SPINEL_HOME", "bin/spin"), "SPINEL_HOME/bin/spin"),
          check_exec("roundhouse", optional_path("ROUNDHOUSE_BIN"), "ROUNDHOUSE_BIN"),
          check_file("sqlite3.c", optional_path("SQLITE_SRC", "sqlite3.c"), "SQLITE_SRC/sqlite3.c"),
          check_writable_dir("CACHE", self["CACHE"])
        ]
      end

      def target_checks(mode, target:, web_dir:)
        case mode
        when :wasm then wasm_checks(web_dir)
        when :native then native_checks
        when :iphonesimulator, :iphoneos then ios_checks(mode)
        else
          raise ArgumentError, "Unknown doctor target: #{target}"
        end
      end

      def wasm_checks(web_dir)
        wasm_opt = self.class.which("wasm-opt")
        [
          check_file("spinel wasm-rt", optional_path("SPINEL_HOME", "lib/wasm32-wasi/libspinel_rt.a"), "SPINEL_HOME/lib/wasm32-wasi/libspinel_rt.a (run `make wasm-rt`)"),
          check_exec("wasi clang", optional_path("WASI_SDK", "bin/clang"), "WASI_SDK/bin/clang"),
          check_exec("wasi llvm-ar", optional_path("WASI_SDK", "bin/llvm-ar"), "WASI_SDK/bin/llvm-ar"),
          check_exec("wasi llvm-strip", optional_path("WASI_SDK", "bin/llvm-strip"), "WASI_SDK/bin/llvm-strip"),
          check_command("npx", "Node/npm on PATH"),
          check_web_modules(web_dir),
          check_rails_gems,
          Check.new(name: "wasm-opt", status: wasm_opt ? :ok : :optional, detail: wasm_opt || "not on PATH (optional binaryen pass)")
        ]
      end

      def native_checks
        cc = ENV.fetch("CC", "cc")
        [
          check_file("spinel rt", optional_path("SPINEL_HOME", "lib/libspinel_rt.a"), "SPINEL_HOME/lib/libspinel_rt.a (run `make`)"),
          check_command(cc, "C compiler (#{cc})"),
          check_command("ar", "archiver (ar)")
        ]
      end

      def ios_checks(mode)
        [
          check_file("spinel Makefile", optional_path("SPINEL_HOME", "Makefile"), "SPINEL_HOME/Makefile"),
          check_xcode_sdk(mode.to_s),
          check_command("ar", "archiver (ar)")
        ]
      end

      def optional_path(key, *parts)
        base = self[key]
        return nil if base.nil? || base.empty?

        parts.empty? ? base : File.join(base, *parts)
      end

      def check_exec(name, path, hint)
        if path && File.file?(path) && File.executable?(path)
          Check.new(name: name, status: :ok, detail: path)
        else
          Check.new(name: name, status: :missing, detail: "not executable: #{path || hint}")
        end
      end

      def check_file(name, path, hint)
        if path && File.file?(path)
          Check.new(name: name, status: :ok, detail: path)
        else
          Check.new(name: name, status: :missing, detail: "not found: #{path || hint}")
        end
      end

      def check_command(command, label)
        found = self.class.which(command)
        if found
          Check.new(name: command, status: :ok, detail: found)
        else
          Check.new(name: command, status: :missing, detail: "#{label} not found on PATH")
        end
      end

      def check_writable_dir(name, dir)
        if dir && !dir.empty?
          ancestor = nearest_existing_ancestor(dir)
          if File.directory?(ancestor) && File.writable?(ancestor)
            return Check.new(name: name, status: :ok, detail: dir)
          end
        end
        detail = (dir && !dir.empty?) ? dir : name
        Check.new(name: name, status: :missing, detail: "not writable: #{detail}")
      end

      def nearest_existing_ancestor(path)
        probe = File.expand_path(path)
        until File.exist?(probe) || File.symlink?(probe)
          parent = File.dirname(probe)
          break if parent == probe

          probe = parent
        end
        probe
      end

      def check_web_modules(web_dir)
        configured = optional_path("WEB_NODE_MODULES")
        local = web_dir && File.join(web_dir, "node_modules")
        if configured && File.directory?(configured)
          Check.new(name: "WEB_NODE_MODULES", status: :ok, detail: configured)
        elsif local && File.directory?(local)
          Check.new(name: "WEB_NODE_MODULES", status: :ok, detail: "#{local} (local)")
        else
          Check.new(name: "WEB_NODE_MODULES", status: :missing, detail: "missing directory: #{configured || 'WEB_NODE_MODULES'}")
        end
      end

      def check_rails_gems
        configured = optional_path("RAILS_GEMS")
        if configured && File.directory?(configured)
          Check.new(name: "RAILS_GEMS", status: :ok, detail: configured)
        elsif %w[turbo-rails stimulus-rails].all? { |gem_name| Gem.loaded_specs.key?(gem_name) }
          Check.new(name: "RAILS_GEMS", status: :ok, detail: "resolved from Gem.loaded_specs")
        else
          Check.new(name: "RAILS_GEMS", status: :missing, detail: "missing directory: #{configured || 'RAILS_GEMS'}")
        end
      end

      def check_xcode_sdk(sdk)
        out, status = Open3.capture2e("xcrun", "--sdk", sdk, "--show-sdk-path")
        detail = out.strip
        if status.success? && !detail.empty?
          Check.new(name: "#{sdk} SDK", status: :ok, detail: detail)
        else
          Check.new(name: "#{sdk} SDK", status: :missing, detail: detail.empty? ? "xcrun failed" : detail)
        end
      rescue Errno::ENOENT
        Check.new(name: "#{sdk} SDK", status: :missing, detail: "xcrun not found on PATH")
      end
    end
  end
end
