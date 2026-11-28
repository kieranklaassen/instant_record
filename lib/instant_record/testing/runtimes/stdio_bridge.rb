require "fileutils"
require "json"
require "open3"

module InstantRecord
  module Testing
    module Runtimes
      # Shared NDJSON stdio bridge plumbing for persistent subprocess runtimes
      # (CRubyRuntime and WasmRuntime). Speaks synchronous line-delimited JSON
      # over stdin/stdout so FaultNetwork can answer inline "exchange" callbacks.
      module StdioBridge
        private

        def bridge_label
          (defined?(@bridge_label) && @bridge_label) || "Bridge"
        end

        def start_bridge!(*command, label:)
          @bridge_label = label
          @stdin, @stdout, @stderr, @wait_thr = Open3.popen3(*command)
          @stdin.sync = true

          ready = read_message
          return ready if ready && ready["type"] == "ready"

          err_out = read_bridge_stderr
          raise InstantRecord::Testing::Error, "#{bridge_label} bridge failed to start: #{ready.inspect} #{err_out}"
        rescue StandardError
          close_bridge_io
          raise
        end

        def rpc(payload)
          op = payload[:op] || payload["op"]
          @stdin.puts(JSON.generate(payload))
          @stdin.flush

          loop do
            msg = read_message
            unless msg
              err_out = read_bridge_stderr
              raise InstantRecord::Testing::Error, "#{bridge_label} bridge exited unexpectedly during #{op}: #{err_out}"
            end

            case msg["type"]
            when "exchange"
              reply = @network.exchange(msg["client"], msg["method"], msg["url"], msg["body"].to_s)
              @stdin.puts(JSON.generate({ status: reply[:status], body: reply[:body].to_s }))
              @stdin.flush
            when "result"
              return msg
            when "error"
              raise InstantRecord::Testing::Error, "#{bridge_label} bridge error during #{op}: #{msg['message']}"
            else
              raise InstantRecord::Testing::Error, "Unexpected #{bridge_label} bridge message: #{msg.inspect}"
            end
          end
        end

        def clean_rpc(op, client_id, context: "#{op}(#{client_id})", **params)
          prefix = respond_to?(:name) ? name : bridge_label.downcase
          rpc({ op: op, client: client_id, **params }).tap do |res|
            assert_clean_stderr!(res["errors"], context: "#{prefix} #{context}")
          end
        end

        def close_bridge(cleanup_dir: nil)
          if defined?(@stdin) && @stdin && !@stdin.closed?
            begin
              rpc({ op: "shutdown" })
            rescue StandardError
              nil
            end
          end
        ensure
          begin
            close_bridge_io
          ensure
            FileUtils.remove_entry(cleanup_dir) if cleanup_dir && Dir.exist?(cleanup_dir)
          end
        end

        def close_bridge_io
          [
            defined?(@stdin) ? @stdin : nil,
            defined?(@stdout) ? @stdout : nil,
            defined?(@stderr) ? @stderr : nil
          ].each do |io|
            io.close if io && !io.closed?
          rescue StandardError
            nil
          end
          return unless defined?(@wait_thr) && @wait_thr

          wait_thr = @wait_thr
          @wait_thr = nil
          return if wait_thr.join(2)

          signal_bridge(wait_thr.pid, "TERM")
          return if wait_thr.join(1)

          signal_bridge(wait_thr.pid, "KILL")
          wait_thr.join(1)
        end

        def signal_bridge(pid, signal)
          Process.kill(signal, pid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end

        def read_message
          line = @stdout.gets
          return nil unless line

          JSON.parse(line)
        end

        def read_bridge_stderr
          return "" unless defined?(@stderr) && @stderr && !@stderr.closed?

          out = +""
          loop do
            out << @stderr.read_nonblock(4096)
          end
        rescue IO::WaitReadable, EOFError
          out
        end
      end
    end
  end
end
