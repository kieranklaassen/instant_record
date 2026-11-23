require "base64"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "uri"
require_relative "base"

module InstantRecord
  module Testing
    module Runtimes
      # Compiled app.wasm runtime driven headlessly in Node via compiled/web/src/app-host.js.
      # Compiles the WebAssembly.Module once per WasmRuntime instance and hosts N
      # isolated AppHost instances inside one fast persistent Node process.
      class WasmRuntime
        include Base

        BRIDGE_SCRIPT = File.expand_path("../wasm_host_bridge.mjs", __dir__)

        class ClientHandle
          attr_reader :id, :runtime

          def initialize(id:, runtime:)
            @id = id.to_s
            @runtime = runtime
          end

          def runtime_name = :wasm

          def request(method, path, body: "", content_type: "application/x-www-form-urlencoded")
            @runtime.execute_request(self, method, path, body: body, content_type: content_type)
          end

          # Mirrors compiled/web/src/worker.js:
          # 1. Run wasm_sync (drains outbox and bootstraps if not yet bootstrapped).
          # 2. If bootstrapped, poll GET /events?after=<cursor>&window=0[&identity=<id>]
          #    through FaultNetwork and feed the SSE response into wasm_stream.
          # 3. If an identity reset arrived on the stream, run one follow-up wasm_sync
          #    so the client re-bootstraps under the new identity.
          def sync(endpoint = InstantRecord::DEFAULT_MOUNT_PATH)
            @runtime.execute_sync(self, endpoint)
          end

          def sync_pass_only(endpoint = InstantRecord::DEFAULT_MOUNT_PATH)
            @runtime.execute_sync_pass_only(self, endpoint)
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

          def verify_frontend_http
            @runtime.execute_verify_frontend_http(self)
          end

          def snapshot_state(model_names:)
            bytes = @runtime.database_bytes(self)
            @runtime.read_sqlite_bytes_state(bytes, model_names: model_names)
          end
        end

        attr_reader :wasm_path, :network

        def initialize(wasm_path:, web_node_modules:, network:)
          @wasm_path = File.expand_path(wasm_path.to_s)
          @web_node_modules = File.expand_path(web_node_modules.to_s)
          @network = network
          @stage_dir = nil
          @stdin = nil
          @stdout = nil
          @stderr = nil
          @wait_thr = nil
          start_bridge!
        end

        def name = :wasm

        def create_client(client_id, env: {})
          res = rpc({ op: "create_client", client: client_id.to_s, env: env })
          assert_clean_stderr!(res["errors"], context: "wasm boot(#{client_id})")
          ClientHandle.new(id: client_id, runtime: self)
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
          FileUtils.remove_entry(@stage_dir) if @stage_dir && Dir.exist?(@stage_dir)
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
          assert_clean_stderr!(res["errors"], context: "wasm request(#{client.id}, #{method} #{path})")
          if res["exit"] != 0
            raise InstantRecord::Testing::Error, "wasm_request exited with #{res['exit']} on #{method} #{path}"
          end
          {
            status: res["status"].to_i,
            headers: res["headers"] || [],
            body: res["body"].to_s,
            exit: res["exit"],
            errors: res["errors"] || []
          }
        end

        def execute_sync_pass_only(client, endpoint)
          res, fault_fired = @network.track_faults do
            rpc({ op: "sync", client: client.id, endpoint: endpoint.to_s })
          end
          assert_clean_stderr!(res["errors"], context: "wasm sync(#{client.id})", allow_offline_warning: fault_fired)
          if res["exit"] != 0
            raise InstantRecord::Testing::Error, "wasm_sync exited with #{res['exit']} (errors=#{res['errors'].inspect})"
          end
          if res["pending"].to_i < 0
            raise InstantRecord::Testing::Error, "wasm_sync reported pending=#{res['pending']} (expected >= 0)"
          end
          {
            changed: !!res["changed"],
            pending: res["pending"].to_i,
            cursor: res["cursor"].to_i,
            notified: !!res["notified"],
            changes: normalize_changes(res["changes"]),
            exchanges: res["exchanges"] || [],
            exit: res["exit"],
            errors: res["errors"] || [],
            fault_fired: fault_fired
          }
        end

        def execute_sync(client, endpoint)
          pass = execute_sync_pass_only(client, endpoint)
          state = execute_sync_state(client)
          return pass unless state[:bootstrapped]

          # Mirror compiled/web/src/worker.js: pull inbound SSE catch-up and feed
          # into wasm_stream (since main_wasm.rb sets Client.streaming = true).
          events_url = "#{endpoint}/events?after=#{state[:cursor]}&window=0"
          events_url += "&identity=#{state[:identity]}" unless state[:identity].empty?

          reply, poll_fault = @network.track_faults do
            @network.exchange(client.id, "GET", events_url, "")
          end
          pass[:exchanges] << "GET #{events_url} -> #{reply[:status]}"
          pass[:fault_fired] ||= poll_fault

          if reply[:status].to_i >= 200 && reply[:status].to_i < 300 && !reply[:body].to_s.empty?
            stream_res = execute_consume_stream(client, reply[:body])
            pass[:changed] ||= stream_res[:applied] > 0
            pass[:cursor] = stream_res[:cursor]
            if stream_res[:notified]
              pass[:notified] = true
              pass[:changes] = stream_res[:changes]
            end
          end

          pass
        end

        def execute_sync_plan(client)
          res = rpc({ op: "sync_plan", client: client.id })
          assert_clean_stderr!(res["errors"], context: "wasm sync_plan(#{client.id})")
          res["plan"]
        end

        def execute_consume_stream(client, chunk)
          res = rpc({ op: "consume_stream", client: client.id, chunk: chunk.to_s })
          assert_clean_stderr!(res["errors"], context: "wasm consume_stream(#{client.id})")
          if res["exit"] != 0
            raise InstantRecord::Testing::Error, "wasm_stream exited with #{res['exit']} (errors=#{res['errors'].inspect})"
          end
          {
            applied: res["applied"].to_i,
            cursor: res["cursor"].to_i,
            bootstrapped: !!res["bootstrapped"],
            notified: !!res["notified"],
            changes: normalize_changes(res["changes"]),
            exit: res["exit"],
            errors: res["errors"] || []
          }
        end

        def execute_sync_state(client)
          res = rpc({ op: "sync_state", client: client.id })
          assert_clean_stderr!(res["errors"], context: "wasm sync_state(#{client.id})")
          {
            bootstrapped: !!res["bootstrapped"],
            cursor: res["cursor"].to_i,
            pending: res["pending"].to_i,
            identity: res["identity"].to_s
          }
        end

        def execute_history(client, key, response)
          res = rpc({ op: "history", client: client.id, key: key.to_s, response: response.to_s })
          assert_clean_stderr!(res["errors"], context: "wasm history(#{client.id})")
          res["history"]
        end

        def execute_local_write(client, model:, operation:, id:, attributes:)
          attrs = attributes.transform_keys(&:to_s)
          case [model.to_s, operation.to_s]
          when ["Issue", "create"]
            res = execute_request(client, "POST", "/todo/issues", body: URI.encode_www_form("issue[title]" => attrs["title"]), content_type: "application/x-www-form-urlencoded")
            raise Error, "Expected 200/302 on POST /todo/issues, got #{res[:status]}" unless [200, 302, 303].include?(res[:status])
            newest_id_from_snapshot(client, "Issue", title: attrs["title"])
          when ["Issue", "update"]
            done = attrs["state"].to_s == "done" ? "1" : "0"
            res = execute_request(client, "POST", "/todo/issues/#{id}", body: URI.encode_www_form("_method" => "patch", "done" => done), content_type: "application/x-www-form-urlencoded")
            raise Error, "Expected 200/302 on PATCH /todo/issues/#{id}, got #{res[:status]}" unless [200, 302, 303].include?(res[:status])
            id
          when ["Issue", "destroy"]
            res = execute_request(client, "POST", "/todo/issues/#{id}", body: URI.encode_www_form("_method" => "delete"), content_type: "application/x-www-form-urlencoded")
            raise Error, "Expected 200/302 on DELETE /todo/issues/#{id}, got #{res[:status]}" unless [200, 302, 303].include?(res[:status])
            id
          when ["AuthNote", "create"]
            form = {
              "note[title]" => attrs["title"],
              "note[body]" => attrs["body"].to_s,
              "note[audience]" => attrs["audience"] || "owner",
              "note[owner_id]" => attrs["owner_id"].to_s
            }
            res = execute_request(client, "POST", "/auth/notes", body: URI.encode_www_form(form), content_type: "application/x-www-form-urlencoded")
            raise Error, "Expected 200/302 on POST /auth/notes, got #{res[:status]}" unless [200, 302, 303].include?(res[:status])
            newest_id_from_snapshot(client, "AuthNote", title: attrs["title"])
          when ["AuthNote", "destroy"]
            res = execute_request(client, "POST", "/auth/notes/#{id}", body: URI.encode_www_form("_method" => "delete"), content_type: "application/x-www-form-urlencoded")
            raise Error, "Expected 200/302 on DELETE /auth/notes/#{id}, got #{res[:status]}" unless [200, 302, 303].include?(res[:status])
            id
          else
            raise ArgumentError, "Unsupported compiled local_write: #{model}##{operation}"
          end
        end

        def execute_verify_frontend_http(client)
          http_path = File.join(InstantRecord::Testing.gem_root.to_s, "frontend/http.js")
          res = rpc({ op: "verify_frontend_http", client: client.id, httpPath: http_path })
          assert_clean_stderr!(res["errors"], context: "wasm frontend/http.js(#{client.id})")
          res
        end

        def database_bytes(client)
          res = rpc({ op: "database_bytes", client: client.id })
          Base64.strict_decode64(res["base64"].to_s)
        end

        private

        def normalize_changes(list)
          return nil if list.nil?

          Array(list).map { |c| { type: c["type"].to_s, id: c["id"].to_s } }
        end

        def newest_id_from_snapshot(client, model_name, title:)
          state = read_sqlite_bytes_state(database_bytes(client), model_names: [model_name])
          rows = state[:tables][model_name].select { |r| r["title"] == title }
          rows.max_by { |r| r["created_at"].to_s }&.fetch("id")
        end

        def prepare_app_host_path
          gem_root = InstantRecord::Testing.gem_root.to_s
          direct = File.join(gem_root, "compiled/web/src/app-host.js")
          if File.directory?(File.join(gem_root, "compiled/web/node_modules/@bjorn3/browser_wasi_shim"))
            return direct
          end

          # Stage app-host.js + changes.js beside a symlinked node_modules so ESM
          # resolution of @bjorn3/browser_wasi_shim works on every Node version
          # without modifying the working tree.
          @stage_dir = Dir.mktmpdir("instant-record-wasm-host")
          File.symlink(@web_node_modules, File.join(@stage_dir, "node_modules"))
          FileUtils.cp(File.join(gem_root, "compiled/web/src/app-host.js"), File.join(@stage_dir, "app-host.js"))
          FileUtils.cp(File.join(gem_root, "compiled/web/src/changes.js"), File.join(@stage_dir, "changes.js"))
          File.join(@stage_dir, "app-host.js")
        end

        def start_bridge!
          app_host_js = prepare_app_host_path
          frontend_http = File.join(InstantRecord::Testing.gem_root.to_s, "frontend/http.js")
          @stdin, @stdout, @stderr, @wait_thr = Open3.popen3("node", BRIDGE_SCRIPT, app_host_js, @wasm_path, frontend_http)
          @stdin.sync = true

          ready = read_message
          unless ready && ready["type"] == "ready"
            err_out = read_bridge_stderr
            raise InstantRecord::Testing::Error, "Wasm bridge failed to start: #{ready.inspect} #{err_out}"
          end
        end

        def rpc(payload)
          @stdin.puts(JSON.generate(payload))
          @stdin.flush

          loop do
            msg = read_message
            unless msg
              err_out = read_bridge_stderr
              raise InstantRecord::Testing::Error, "Wasm bridge exited unexpectedly during #{payload[:op]}: #{err_out}"
            end

            case msg["type"]
            when "exchange"
              reply = @network.exchange(msg["client"], msg["method"], msg["url"], msg["body"].to_s)
              @stdin.puts(JSON.generate({ status: reply[:status], body: reply[:body].to_s }))
              @stdin.flush
            when "result"
              return msg
            when "error"
              raise InstantRecord::Testing::Error, "Wasm bridge error during #{payload[:op]}: #{msg['message']}"
            else
              raise InstantRecord::Testing::Error, "Unexpected Wasm bridge message: #{msg.inspect}"
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
            chunk = @stderr.read_nonblock(4096)
            out << chunk
          end
        rescue IO::WaitReadable, EOFError
          out
        end
      end
    end
  end
end
