require "rbconfig"
require "tmpdir"
require_relative "base"
require_relative "client_handle"
require_relative "stdio_bridge"

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
        include StdioBridge

        BRIDGE_SCRIPT = File.expand_path("../cruby_host_bridge.rb", __dir__)

        class ClientHandle < Runtimes::ClientHandle
          attr_reader :db_path

          def initialize(id:, runtime:, db_path:)
            super(id: id, runtime: runtime)
            @db_path = db_path
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
          lib_dir = File.join(InstantRecord::Testing.gem_root.to_s, "lib")
          start_bridge!(RbConfig.ruby, "-I#{lib_dir}", BRIDGE_SCRIPT, @tmpdir, label: "CRuby")
        rescue StandardError
          close
          raise
        end

        def name = :cruby

        def create_client(client_id, env: {})
          _ = env
          res = clean_rpc("create_client", client_id.to_s)
          ClientHandle.new(id: client_id, runtime: self, db_path: res["db_path"])
        end

        def close
          close_bridge(cleanup_dir: @tmpdir)
        end

        def execute_request(client, method, path, body:, content_type:)
          res = clean_rpc(
            "request",
            client.id,
            context: "request(#{client.id}, #{method} #{path})",
            method: method.to_s.upcase,
            path: path.to_s,
            body: body.to_s,
            contentType: content_type
          )
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
          clean_rpc("sync_plan", client.id)["plan"]
        end

        def execute_consume_stream(client, chunk)
          res = clean_rpc("consume_stream", client.id, chunk: chunk.to_s)
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

        def execute_local_write(client, model:, operation:, id:, attributes:)
          skew = @network.policy(client.id).clock_skew.to_f
          res = clean_rpc(
            "local_write",
            client.id,
            context: "local_write(#{client.id}, #{model}##{operation})",
            model: model.to_s,
            operation: operation.to_s,
            id: id,
            attributes: attributes,
            clockSkew: skew
          )
          res["record_id"]
        end
      end
    end
  end
end
