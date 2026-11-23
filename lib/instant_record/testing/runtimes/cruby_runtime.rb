require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "base"

module InstantRecord
  module Testing
    module Runtimes
      # Multi-client CRuby runtime driving InstantRecord::Client through its
      # injectable transport and notifier seams (lib/instant_record/client.rb:28-38)
      # inside an isolated persistent SQLite-only CRuby child process.
      #
      # Isolating CRuby clients in their own process mirrors WasmRuntime (Node)
      # and prevents ActiveRecord StatementCache / adapter collisions when the
      # authoritative server runs on PostgreSQL.
      class CRubyRuntime
        include Base

        BRIDGE_SCRIPT = File.expand_path("../cruby_host_bridge.rb", __dir__)

        class ClientHandle
          attr_reader :id, :runtime, :db_path

          def initialize(id:, runtime:, db_path:)
            @id = id.to_s
            @runtime = runtime
            @db_path = db_path
          end

          def runtime_name = :cruby

          def request(method, path, body: "", content_type: "application/x-www-form-urlencoded")
            @runtime.execute_request(self, method, path, body: body, content_type: content_type)
          end

          def sync(endpoint = InstantRecord::DEFAULT_MOUNT_PATH)
            @runtime.execute_sync(self, endpoint)
          end

          def sync_plan
            @runtime.execute_sync_plan(self)
          end

          def consume_stream(chunk)
            @runtime.execute_consume_stream(self, chunk)
          end

          def sync_state
            @runtime.execute_sync_state(self)
          end

          def history(key, response = "")
            @runtime.execute_history(self, key, response)
          end

          def local_write(model:, operation:, id: nil, attributes: {})
            @runtime.execute_local_write(self, model: model, operation: operation, id: id, attributes: attributes)
          end

          def snapshot_state(model_names:)
            @runtime.read_sqlite_file_state(@db_path, model_names: model_names)
          end
        end

        attr_reader :network, :server

        def initialize(network:, server:, model_names: %w[Issue AuthNote])
          @network = network
          @server = server
          @model_names = Array(model_names)
          @tmpdir = Dir.mktmpdir("instant-record-cruby-clients")
          @stdin = nil
          @stdout = nil
          @stderr = nil
          @wait_thr = nil
          start_bridge!
        end

        def name = :cruby

        def create_client(client_id, env: {})
          _ = env
          res = rpc({ op: "create_client", client: client_id.to_s })
          assert_clean_stderr!(res["errors"], context: "cruby create_client(#{client_id})")
          ClientHandle.new(id: client_id, runtime: self, db_path: res["db_path"])
        end

        def close
          if @stdin && !@stdin.closed?
            begin
              rpc({ op: "shutdown" })
            rescue StandardError
              nil
            end
          end
        ensure
          [@stdin, @stdout, @stderr].each do |io|
            io.close if io && !io.closed?
          rescue StandardError
            nil
          end
          @wait_thr&.join(2)
          FileUtils.remove_entry(@tmpdir) if @tmpdir && Dir.exist?(@tmpdir)
        end

        def execute_request(client, method, path, body:, content_type:)
          res = rpc({
            op: "request",
            client: client.id,
            method: method.to_s.upcase,
            path: path.to_s,
            body: body.to_s,
            contentType: content_type
          })
          assert_clean_stderr!(res["errors"], context: "cruby request(#{client.id}, #{method} #{path})")
          {
            status: res["status"].to_i,
            headers: res["headers"] || [],
            body: res["body"].to_s,
            exit: res["exit"].to_i,
            errors: res["errors"] || []
          }
        end

        def execute_sync(client, endpoint)
          res, fault_fired = @network.track_faults do
            rpc({ op: "sync", client: client.id, endpoint: endpoint.to_s })
          end
          assert_clean_stderr!(res["errors"], context: "cruby sync(#{client.id})", allow_offline_warning: fault_fired)
          {
            changed: !!res["changed"],
            pending: res["pending"].to_i,
            cursor: res["cursor"].to_i,
            **parse_notice(res["notice"]),
            exchanges: res["exchanges"] || [],
            exit: res["exit"].to_i,
            errors: res["errors"] || [],
            fault_fired: fault_fired
          }
        end

        def execute_sync_plan(client)
          res = rpc({ op: "sync_plan", client: client.id })
          assert_clean_stderr!(res["errors"], context: "cruby sync_plan(#{client.id})")
          res["plan"]
        end

        def execute_consume_stream(client, chunk)
          res = rpc({ op: "consume_stream", client: client.id, chunk: chunk.to_s })
          assert_clean_stderr!(res["errors"], context: "cruby consume_stream(#{client.id})")
          {
            applied: res["applied"].to_i,
            cursor: res["cursor"].to_i,
            bootstrapped: !!res["bootstrapped"],
            **parse_notice(res["notice"]),
            exit: res["exit"].to_i,
            errors: res["errors"] || []
          }
        end

        def execute_sync_state(client)
          res = rpc({ op: "sync_state", client: client.id })
          assert_clean_stderr!(res["errors"], context: "cruby sync_state(#{client.id})")
          {
            bootstrapped: !!res["bootstrapped"],
            cursor: res["cursor"].to_i,
            pending: res["pending"].to_i,
            identity: res["identity"].to_s
          }
        end

        def execute_history(client, key, response)
          res = rpc({ op: "history", client: client.id, key: key.to_s, response: response.to_s })
          assert_clean_stderr!(res["errors"], context: "cruby history(#{client.id})")
          res["history"]
        end

        def execute_local_write(client, model:, operation:, id:, attributes:)
          skew = @network.policy(client.id).clock_skew.to_f
          res = rpc({
            op: "local_write",
            client: client.id,
            model: model.to_s,
            operation: operation.to_s,
            id: id,
            attributes: attributes,
            clockSkew: skew
          })
          assert_clean_stderr!(res["errors"], context: "cruby local_write(#{client.id}, #{model}##{operation})")
          res["record_id"]
        end

        private

        def start_bridge!
          lib_dir = File.join(InstantRecord::Testing.gem_root.to_s, "lib")
          @stdin, @stdout, @stderr, @wait_thr = Open3.popen3(RbConfig.ruby, "-I#{lib_dir}", BRIDGE_SCRIPT, @tmpdir)
          @stdin.sync = true

          ready = read_message
          unless ready && ready["type"] == "ready"
            err_out = read_bridge_stderr
            raise InstantRecord::Testing::Error, "CRuby bridge failed to start: #{ready.inspect} #{err_out}"
          end
        end

        def rpc(payload)
          @stdin.puts(JSON.generate(payload))
          @stdin.flush

          loop do
            msg = read_message
            unless msg
              err_out = read_bridge_stderr
              raise InstantRecord::Testing::Error, "CRuby bridge exited unexpectedly during #{payload[:op]}: #{err_out}"
            end

            case msg["type"]
            when "exchange"
              reply = @network.exchange(msg["client"], msg["method"], msg["url"], msg["body"].to_s)
              @stdin.puts(JSON.generate({ status: reply[:status], body: reply[:body].to_s }))
              @stdin.flush
            when "result"
              return msg
            when "error"
              raise InstantRecord::Testing::Error, "CRuby bridge error during #{payload[:op]}: #{msg['message']}"
            else
              raise InstantRecord::Testing::Error, "Unexpected CRuby bridge message: #{msg.inspect}"
            end
          end
        end

        def read_message
          line = @stdout.gets
          return nil unless line

          JSON.parse(line)
        end

        def read_bridge_stderr
          return "" unless @stderr && !@stderr.closed?

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
