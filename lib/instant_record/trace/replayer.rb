require "json"
require "open3"
require "pathname"

module InstantRecord
  module Trace
    # Runs `compiled/web/src/replay.js` in Node to replay an `.irtrace` file
    # deterministically against a compiled app's `.wasm` module.
    class Replayer
      Result = Struct.new(:ok, :status, :stdout, :stderr, :report, keyword_init: true) do
        def ok? = !!ok
      end

      def self.gem_root
        Pathname(__dir__).join("../../..").realpath
      end

      def self.replay_script
        gem_root.join("compiled/web/src/replay.js").to_s
      end

      def initialize(
        trace_path:,
        wasm_path: nil,
        db_path: nil,
        root: nil,
        toolchain: nil,
        node_modules: nil,
        json: false,
        allow_digest_mismatch: false,
        stop_on_fault: false,
        max_steps: nil,
        node_bin: ENV.fetch("NODE", "node")
      )
        @trace_path = File.expand_path(trace_path.to_s)
        @root = root ? File.expand_path(root.to_s) : nil
        @wasm_path = wasm_path ? File.expand_path(wasm_path.to_s) : discover_wasm
        @db_path = db_path ? File.expand_path(db_path.to_s) : nil
        @toolchain = toolchain
        @node_modules = discover_node_modules(node_modules)
        @json = !!json
        @allow_digest_mismatch = !!allow_digest_mismatch
        @stop_on_fault = !!stop_on_fault
        @max_steps = max_steps
        @node_bin = node_bin
      end

      def run
        raise Error, "Trace file not found: #{@trace_path}" unless File.file?(@trace_path)
        unless @wasm_path && File.file?(@wasm_path)
          raise Error, "Could not find a compiled app-*.wasm module. Pass WASM=/path/to/app.wasm or run bin/rails instant_record:compile first."
        end

        cmd = [@node_bin, self.class.replay_script, @trace_path, "--wasm", @wasm_path]
        cmd.push("--db", @db_path) if @db_path
        @node_modules.each { |dir| cmd.push("--node-modules", dir) }
        cmd << "--json" if @json
        cmd << "--allow-digest-mismatch" if @allow_digest_mismatch
        cmd << "--stop-on-fault" if @stop_on_fault
        cmd.push("--max-steps", @max_steps.to_s) if @max_steps

        stdout, stderr, status =
          begin
            Open3.capture3(*cmd)
          rescue Errno::ENOENT => e
            raise Error, "Node executable not found (#{@node_bin}): #{e.message}"
          end
        report = nil
        if @json && !stdout.strip.empty?
          begin
            report = JSON.parse(stdout)
          rescue JSON::ParserError
            report = nil
          end
        end

        Result.new(
          ok: status.success?,
          status: status.exitstatus || 1,
          stdout: stdout,
          stderr: stderr,
          report: report
        )
      end

      private

      def discover_wasm
        search_roots = []
        if @root
          search_roots << File.join(@root, "tmp/instant_record/compiled/web/dist")
          search_roots << File.join(@root, "public/instant_record_compiled/current")
        end
        search_roots << self.class.gem_root.join("compiled/web/dist").to_s

        search_roots.each do |dir|
          next unless File.directory?(dir)

          candidates = Dir.glob(File.join(dir, "app*.wasm")).filter_map do |path|
            [path, -File.mtime(path).to_f]
          rescue Errno::ENOENT
            nil
          end
          best = candidates.min_by(&:last)
          return best.first if best
        end
        nil
      end

      def discover_node_modules(explicit)
        dirs = []
        Array(explicit).compact.each { |dir| dirs << File.expand_path(dir.to_s) if File.directory?(dir.to_s) }
        if ENV["INSTANT_RECORD_WEB_NODE_MODULES"] && File.directory?(ENV["INSTANT_RECORD_WEB_NODE_MODULES"])
          dirs << File.expand_path(ENV["INSTANT_RECORD_WEB_NODE_MODULES"])
        end
        if @root
          staged = File.join(@root, "tmp/instant_record/compiled/web/node_modules")
          dirs << staged if File.directory?(staged)
        end
        if @toolchain && File.file?(@toolchain.to_s)
          begin
            require "instant_record/compiler/toolchain"
            tc = InstantRecord::Compiler::Toolchain.load(@toolchain)
            nm = tc["WEB_NODE_MODULES"]
            dirs << nm if nm && File.directory?(nm)
          rescue StandardError
            nil
          end
        end
        gem_nm = self.class.gem_root.join("compiled/web/node_modules").to_s
        dirs << gem_nm if File.directory?(gem_nm)
        dirs.uniq
      end
    end
  end
end
