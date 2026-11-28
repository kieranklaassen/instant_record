module InstantRecord
  module Testing
    module Runtimes
      # Shared client handle base delegating standard sync, request, stream,
      # history, and local_write operations to the owning runtime driver.
      class ClientHandle
        attr_reader :id, :runtime

        def initialize(id:, runtime:)
          @id = id.to_s
          @runtime = runtime
        end

        def runtime_name
          @runtime.name
        end

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
      end
    end
  end
end
