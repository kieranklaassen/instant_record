require "base64"
require "fileutils"
require "tmpdir"
require_relative "base"
require_relative "client_handle"
require_relative "compiled_local_writes"
require_relative "stdio_bridge"

module InstantRecord
  module Testing
    module Runtimes
      # Compiled app.wasm runtime driven headlessly in Node via compiled/web/src/app-host.js.
      # Compiles the WebAssembly.Module once per WasmRuntime instance and hosts N
      # isolated AppHost instances inside one fast persistent Node process.
      class WasmRuntime
        include Base
        include CompiledLocalWrites
        include StdioBridge

        BRIDGE_SCRIPT = File.expand_path("../wasm_host_bridge.mjs", __dir__)

        class ClientHandle < Runtimes::ClientHandle
          def sync_pass_only(endpoint = InstantRecord::DEFAULT_MOUNT_PATH)
            @runtime.execute_sync_pass_only(self, endpoint)
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
          app_host_js = prepare_app_host_path
          frontend_http = File.join(InstantRecord::Testing.gem_root.to_s, "frontend/http.js")
          start_bridge!("node", BRIDGE_SCRIPT, app_host_js, @wasm_path, frontend_http, label: "Wasm")
        rescue StandardError
          close
          raise
        end

        def name = :wasm

        def create_client(client_id, env: {})
          clean_rpc("create_client", client_id.to_s, context: "boot(#{client_id})", env: env)
          ClientHandle.new(id: client_id, runtime: self)
        end

        def close
          close_bridge(cleanup_dir: @stage_dir)
        end

        def execute_request(client, method, path, body:, content_type:)
          res = clean_rpc("request", client.id, context: "request(#{client.id}, #{method} #{path})",
            method: method.to_s.upcase, path: path.to_s, body: body.to_s, contentType: content_type)
          assert_exit_zero!(res, "wasm_request", "on #{method} #{path}")
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
          assert_exit_zero!(res, "wasm_sync")
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
          clean_rpc("sync_plan", client.id)["plan"]
        end

        def execute_consume_stream(client, chunk)
          res = clean_rpc("consume_stream", client.id, chunk: chunk.to_s)
          assert_exit_zero!(res, "wasm_stream")
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
          res = clean_rpc("sync_state", client.id)
          {
            bootstrapped: !!res["bootstrapped"],
            cursor: res["cursor"].to_i,
            pending: res["pending"].to_i,
            identity: res["identity"].to_s
          }
        end

        def execute_history(client, key, response)
          clean_rpc("history", client.id, key: key.to_s, response: response.to_s)["history"]
        end

        def execute_verify_frontend_http(client)
          http_path = File.join(InstantRecord::Testing.gem_root.to_s, "frontend/http.js")
          clean_rpc("verify_frontend_http", client.id, context: "frontend/http.js(#{client.id})", httpPath: http_path)
        end

        def database_bytes(client)
          res = rpc({ op: "database_bytes", client: client.id })
          Base64.strict_decode64(res["base64"].to_s)
        end

        private

        def local_write_kind = "compiled"

        def assert_exit_zero!(res, function, detail = "(errors=#{res['errors'].inspect})")
          return if res["exit"] == 0

          raise InstantRecord::Testing::Error, "#{function} exited with #{res['exit']} #{detail}"
        end

        def normalize_changes(list)
          return nil if list.nil?

          Array(list).map { |c| { type: c["type"].to_s, id: c["id"].to_s } }
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
      end
    end
  end
end
