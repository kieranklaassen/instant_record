require "fileutils"
require "json"
require "tmpdir"
require_relative "base"
require_relative "compiled_local_writes"

module InstantRecord
  module Testing
    module Runtimes
      # Compiled Native C ABI runtime loaded directly in-process via Ruby Fiddle
      # against compiled/pipeline/native/instant_record_native.h:
      #   ir_set_exchange, ir_boot, ir_open, ir_call, ir_notice, ir_error.
      #
      # Because native_shim.c boots Spinel once per process, LibrarySession caches
      # the booted Fiddle handle and multiplexes N isolated client SQLite files
      # seamlessly via ir_open(db_path).
      class NativeRuntime
        include Base
        include CompiledLocalWrites

        # Process-wide booted handle per shared library path.
        class LibrarySession
          @sessions = {}

          def self.for(lib_path)
            canonical = File.realpath(lib_path)
            @sessions[canonical] ||= new(canonical)
          end

          def initialize(lib_path)
            require "fiddle"
            @lib_path = lib_path
            @handle = Fiddle.dlopen(lib_path)
            @ir_set_exchange = Fiddle::Function.new(@handle["ir_set_exchange"], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID)
            @ir_boot = Fiddle::Function.new(@handle["ir_boot"], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
            @ir_open = Fiddle::Function.new(@handle["ir_open"], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
            @ir_call = Fiddle::Function.new(@handle["ir_call"], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOIDP)
            @ir_notice = Fiddle::Function.new(@handle["ir_notice"], [], Fiddle::TYPE_VOIDP)
            @ir_error = Fiddle::Function.new(@handle["ir_error"], [], Fiddle::TYPE_VOIDP)

            @booted = false
            @active_db_path = nil
            @active_exchange = nil
            @pinned_response = nil

            # Pin the closure in an instance variable so it is never GC'd while
            # C holds its function pointer.
            @exchange_closure = Fiddle::Closure::BlockCaller.new(
              Fiddle::TYPE_VOIDP,
              [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
            ) do |req_ptr, _ctx|
              req_str = req_ptr.null? ? "" : req_ptr.to_s
              newline = req_str.index("\n") || req_str.length
              method, url = req_str[0, newline].split(" ", 2)
              body = req_str[(newline + 1)..] || ""
              reply =
                if @active_exchange
                  @active_exchange.call(method.to_s, url.to_s, body)
                else
                  { status: 0, body: "" }
                end
              @pinned_response = "#{reply[:status]}\n#{reply[:body]}\0".b
              Fiddle::Pointer[@pinned_response]
            end

            @ir_set_exchange.call(@exchange_closure, Fiddle::NULL)
          end

          def ensure_open(db_path)
            return [] if @booted && @active_db_path == db_path

            code, stderr_lines = capture_fd2 do
              if @booted
                @ir_open.call(db_path)
              else
                @ir_boot.call(db_path)
              end
            end
            if code != 0
              raise InstantRecord::Testing::Error, "Native #{@booted ? 'ir_open' : 'ir_boot'} failed (#{db_path}): #{last_error}"
            end
            @booted = true
            @active_db_path = db_path
            stderr_lines
          end

          def call_entry(db_path, entry, input, exchange: nil)
            open_stderr = ensure_open(db_path)
            @active_exchange = exchange
            ptr, call_stderr = capture_fd2 { @ir_call.call(entry.to_s, input.to_s) }
            errors = open_stderr + call_stderr

            if ptr.null?
              err = last_error
              errors << err unless err.empty?
              return { ok: false, out: "", notice: "", errors: errors }
            end

            out = ptr.to_s.dup.force_encoding(Encoding::UTF_8)
            notice_ptr = @ir_notice.call
            notice = notice_ptr.null? ? "" : notice_ptr.to_s.dup.force_encoding(Encoding::UTF_8)
            { ok: true, out: out, notice: notice, errors: errors }
          ensure
            @active_exchange = nil
          end

          def last_error
            ptr = @ir_error.call
            ptr.null? ? "" : ptr.to_s.dup.force_encoding(Encoding::UTF_8)
          end

          private

          # Capture C-level stderr (fd 2) around native Fiddle calls so Ruby warn
          # or Spinel runtime diagnostics are caught identically to WASI stderr.
          def capture_fd2
            $stderr.flush
            saved_fd = IO.new(2).dup
            read_io, write_io = IO.pipe
            $stderr.reopen(write_io)
            write_io.close

            result = yield
            $stderr.flush
            $stderr.reopen(saved_fd)
            saved_fd.close
            captured = read_io.read
            read_io.close
            [result, captured.lines(chomp: true)]
          rescue StandardError
            begin
              $stderr.reopen(saved_fd) if saved_fd && !saved_fd.closed?
              saved_fd&.close
              write_io&.close unless write_io&.closed?
              read_io&.close unless read_io&.closed?
            rescue StandardError
              nil
            end
            raise
          end
        end

        class ClientHandle
          attr_reader :id, :runtime, :db_path, :cookies

          def initialize(id:, runtime:, db_path:)
            @id = id.to_s
            @runtime = runtime
            @db_path = db_path
            @cookies = {}
          end

          def runtime_name = :native

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

        attr_reader :lib_path, :network

        def initialize(lib_path:, network:)
          @lib_path = File.expand_path(lib_path.to_s)
          @network = network
          @session = LibrarySession.for(@lib_path)
          @tmpdir = Dir.mktmpdir("instant-record-native-clients")
          @counter = 0
        end

        def name = :native

        def create_client(client_id, env: {})
          _ = env
          @counter += 1
          db_path = File.join(@tmpdir, "#{client_id.to_s.gsub(/[^a-zA-Z0-9_-]/, '_')}_#{@counter}.sqlite3")
          stderr = @session.ensure_open(db_path)
          assert_clean_stderr!(stderr, context: "native boot/open(#{client_id})")
          ClientHandle.new(id: client_id, runtime: self, db_path: db_path)
        end

        def close
          # Point Spinel at a harmless temp db before removing client temp dir
          # so the next NativeRuntime session doesn't hold an unlinked path.
          FileUtils.remove_entry(@tmpdir) if @tmpdir && Dir.exist?(@tmpdir)
        end

        def execute_request(client, method, path, body:, content_type:)
          raw_req = build_http_request(method, path, body: body, content_type: content_type, cookies: client.cookies)
          res = call_entry(client, "request", raw_req, about: "#{client.id}, #{method} #{path}")
          parsed = parse_bridge_http_response(res[:out], cookies: client.cookies)
          parsed.merge(exit: 0, errors: res[:errors])
        end

        def execute_sync(client, endpoint)
          exchanges = []
          exchange_cb = lambda do |method, url, body|
            reply = @network.exchange(client.id, method, url, body)
            exchanges << "#{method} #{url} -> #{reply[:status]}"
            reply
          end

          res, fault_fired = @network.track_faults do
            @session.call_entry(client.db_path, "sync", endpoint.to_s, exchange: exchange_cb)
          end
          check_call!(res, "sync", client.id, allow_offline_warning: fault_fired)

          text = res[:out]
          pending = (text[/pending=(\d+)/, 1] || -1).to_i
          cursor = (text[/cursor=(\d+)/, 1] || 0).to_i
          raise InstantRecord::Testing::Error, "native sync reported pending=#{pending}" if pending < 0

          {
            changed: text.start_with?("changed"),
            pending: pending,
            cursor: cursor,
            **parse_notice(res[:notice]),
            exchanges: exchanges,
            exit: 0,
            errors: res[:errors],
            fault_fired: fault_fired
          }
        end

        def execute_sync_plan(client)
          JSON.parse(call_entry(client, "sync_plan", "")[:out])
        end

        def execute_consume_stream(client, chunk)
          res = call_entry(client, "stream", chunk.to_s)
          text = res[:out]
          {
            applied: (text[/applied=(\d+)/, 1] || 0).to_i,
            cursor: (text[/cursor=(\d+)/, 1] || 0).to_i,
            bootstrapped: !text.include?("bootstrap=needed"),
            **parse_notice(res[:notice]),
            exit: 0,
            errors: res[:errors]
          }
        end

        def execute_sync_state(client)
          text = call_entry(client, "cursor", "")[:out]
          {
            bootstrapped: text.include?("bootstrap=ready"),
            cursor: (text[/cursor=(\d+)/, 1] || 0).to_i,
            pending: (text[/pending=(\d+)/, 1] || 0).to_i,
            identity: text[/identity=(\S+)/, 1].to_s
          }
        end

        def execute_history(client, key, response)
          JSON.parse(call_entry(client, "history", JSON.generate({ key: key.to_s, response: response.to_s }))[:out])
        end

        private

        def local_write_kind = "native"

        def call_entry(client, entry, input, about: client.id)
          check_call!(@session.call_entry(client.db_path, entry, input), entry, about)
        end

        def check_call!(res, entry, about, allow_offline_warning: false)
          assert_clean_stderr!(res[:errors], context: "native #{entry}(#{about})", allow_offline_warning: allow_offline_warning)
          raise InstantRecord::Testing::Error, "native #{entry} failed: #{res[:errors].join('; ')}" unless res[:ok]

          res
        end
      end
    end
  end
end
