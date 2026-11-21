require "fileutils"
require "open3"

module InstantRecord
  class Compiler
    class BuildError < StandardError; end

    # Runs external toolchain binaries (Roundhouse, Spinel, clang, Vite) with
    # captured logs and concise, readable error tails.
    class Runner
      attr_reader :build_dir

      def initialize(build_dir:)
        @build_dir = build_dir.to_s
      end

      def run(args, cwd: nil, env: {}, log: nil)
        cmd = args.map(&:to_s)
        merged_env = env.transform_keys(&:to_s).transform_values { |v| v.nil? ? nil : v.to_s }
        opts = {}
        opts[:chdir] = cwd.to_s if cwd

        output, status = Open3.capture2e(merged_env, *cmd, **opts)
        if log
          FileUtils.mkdir_p(@build_dir)
          File.write(File.join(@build_dir, log), output)
        end

        unless status.success?
          filtered = output.lines.reject { |line| line.include?("--rbs") || line.include?("warning:") }.join
          tail = filtered.length > 1500 ? filtered[-1500..] : filtered
          location = log ? " (see #{File.join(@build_dir, log)})" : ""
          raise BuildError, "build step failed: #{cmd.first(3).join(' ')}#{location}\n#{tail}"
        end

        output
      rescue Errno::ENOENT => e
        raise BuildError, "build step failed: executable #{cmd.first.inspect} not found (#{e.message})"
      end
    end
  end
end
