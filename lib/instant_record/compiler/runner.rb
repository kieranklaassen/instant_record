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
        cmd = Array(args).map(&:to_s)
        raise ArgumentError, "command must not be empty" if cmd.empty?

        merged_env = env.transform_keys(&:to_s).transform_values { |v| v.nil? ? nil : v.to_s }
        opts = {}
        if cwd
          cwd_path = cwd.to_s
          unless File.directory?(cwd_path)
            detail = File.exist?(cwd_path) ? "is not a directory" : "does not exist"
            raise BuildError, "build step failed: working directory #{cwd_path.inspect} #{detail}"
          end
          opts[:chdir] = cwd_path
        end

        output, status = begin
          Open3.capture2e(merged_env, [cmd.first, cmd.first], *cmd[1..], **opts)
        rescue Errno::ENOENT => e
          raise BuildError, "build step failed: executable #{cmd.first.inspect} not found (#{e.message})"
        rescue Errno::EACCES => e
          raise BuildError, "build step failed: executable #{cmd.first.inspect} is not executable (#{e.message})"
        end

        if log
          FileUtils.mkdir_p(@build_dir)
          File.binwrite(File.join(@build_dir, log), output)
        end

        unless status.success?
          filtered = output.scrub.lines.reject { |line| line.include?("--rbs") || line.include?("warning:") }.join
          tail = filtered.length > 1500 ? filtered[-1500..] : filtered
          location = log ? " (see #{File.join(@build_dir, log)})" : ""
          raise BuildError, "build step failed: #{cmd.first(3).join(' ')}#{location}\n#{tail}"
        end

        output
      end
    end
  end
end
