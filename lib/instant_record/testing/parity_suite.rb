require "json"
require "securerandom"
require "uri"

module InstantRecord
  module Testing
    # Executes shared model, controller, sync, 32-bit boundary, identity-reset,
    # mid-bootstrap-abort, split-SSE, and frontend/http.js assertions simultaneously
    # across all active runtimes (CRuby, Wasm AppHost, Native C ABI Fiddle) and
    # asserts empty WASI/native stderr plus bit-for-bit convergence.
    class ParitySuite
      MODELS = %w[Issue AuthNote].freeze
      ENDPOINT = InstantRecord::DEFAULT_MOUNT_PATH

      ScenarioResult = Struct.new(:name, :runtimes, :elapsed_ms, :status, keyword_init: true)

      def initialize(runtimes:, artifacts:, rails_app: nil, database_url: nil, out: $stdout)
        @runtime_names = Array(runtimes).map(&:to_sym)
        @artifacts = artifacts
        @rails_app = rails_app
        @database_url = database_url
        @out = out
      end

      def run
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @server = AuthoritativeServer.build(rails_app: @rails_app, database_url: @database_url, models: MODELS)
        @network = FaultNetwork.new(@server)
        @drivers = build_drivers

        @out.puts "InstantRecord dual-runtime parity (#{@server.backend_label}; runtimes: #{@runtime_names.join(', ')})"

        results = []
        scenarios.each do |scenario_name|
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @server.reset_data!
          @network.heal_all!
          send(:"scenario_#{scenario_name}")
          ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(1)
          results << ScenarioResult.new(name: scenario_name, runtimes: @runtime_names, elapsed_ms: ms, status: :passed)
          @out.puts "  [PASS] #{scenario_name} (#{ms}ms)"
        end

        total_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
        @out.puts "All #{results.size} parity scenarios passed across [#{@runtime_names.join(', ')}] in #{total_ms}ms."
        { ok: true, backend: @server.backend_label, runtimes: @runtime_names, scenarios: results, elapsed_ms: total_ms }
      ensure
        @drivers&.each_value do |driver|
          driver.close
        rescue StandardError
          nil
        end
        @server&.close
      end

      private

      def scenarios
        list = %i[
          boot_and_config_32bit_safety
          controller_crud_and_outbox_sync
          server_only_validation_rejection_rollback
          int32_boundary_values
          identity_scoping_switch_and_reset
          mid_bootstrap_abort_and_idempotent_retry
          split_sse_framing_and_echo_suppression
        ]
        list << :frontend_http_compiled_fetch_path if @runtime_names.include?(:wasm)
        list
      end

      def build_drivers
        @runtime_names.each_with_object({}) do |rt, acc|
          acc[rt] =
            case rt
            when :cruby
              Runtimes::CRubyRuntime.new(network: @network, server: @server, model_names: MODELS)
            when :wasm
              Runtimes::WasmRuntime.new(
                wasm_path: @artifacts.wasm_path,
                web_node_modules: @artifacts.web_node_modules,
                network: @network
              )
            when :native
              Runtimes::NativeRuntime.new(
                lib_path: @artifacts.native_lib_path,
                network: @network
              )
            end
        end
      end

      def spawn_clients(prefix, identity: nil)
        @drivers.each_with_object({}) do |(rt, driver), acc|
          cid = "#{prefix}_#{rt}"
          @network.register_client(cid, identity: identity)
          acc[rt] = driver.create_client(cid)
        end
      end

      def assert_equal!(expected, actual, message)
        return if expected == actual

        raise ParityMismatch, "#{message}\nExpected: #{expected.inspect}\nActual:   #{actual.inspect}"
      end

      def assert_true!(cond, message)
        raise ParityMismatch, message unless cond
      end

      # Assert all clients match the authoritative server's visible state AND
      # match each other bit-for-bit in canonical JSON.
      def assert_converged!(clients, identity: nil, label:)
        expected_tables = @server.visible_state(identity: identity)
        expected_json = InstantRecord::Testing.canonical_json(expected_tables)

        snapshots = {}
        clients.each do |rt, client|
          snap = client.snapshot_state(model_names: MODELS)
          snapshots[rt] = snap

          assert_equal!(0, snap[:pending], "#{label} [#{rt}]: expected pending=0 after convergence")
          snap[:sync_states].each do |model, rows|
            unsynced = rows.reject { |r| r["sync_state"] == "synced" }
            assert_true!(unsynced.empty?, "#{label} [#{rt}]: unsynced #{model} rows remain: #{unsynced.inspect}")
          end

          actual_json = InstantRecord::Testing.canonical_json(snap[:tables])
          unless actual_json == expected_json
            raise ConvergenceError,
              "#{label} [#{rt}] diverged from authoritative server (#{@server.backend_label}):\n" \
              "--- server ---\n#{expected_json}\n--- #{rt} ---\n#{actual_json}"
          end
        end

        # Cross-runtime bit-for-bit comparison.
        ref_rt = clients.keys.first
        ref_json = InstantRecord::Testing.canonical_json(snapshots[ref_rt][:tables])
        snapshots.each do |rt, snap|
          next if rt == ref_rt

          other_json = InstantRecord::Testing.canonical_json(snap[:tables])
          unless other_json == ref_json
            raise ParityMismatch,
              "#{label}: #{rt} diverged from #{ref_rt}:\n--- #{ref_rt} ---\n#{ref_json}\n--- #{rt} ---\n#{other_json}"
          end
        end

        snapshots
      end

      def converge_all!(clients, rounds: 4)
        rounds.times do
          clients.each_value { |c| c.sync(ENDPOINT) }
        end
      end

      # 1. Boot & 32-bit config safety (catches wasm32 RangeError on boot/first sync).
      def scenario_boot_and_config_32bit_safety
        clients = spawn_clients("boot")
        clients.each do |rt, client|
          state = client.sync_state
          assert_equal!(false, state[:bootstrapped], "boot [#{rt}]: must start unbootstrapped")
          assert_equal!(0, state[:cursor], "boot [#{rt}]: cursor must start at 0")
          assert_equal!(0, state[:pending], "boot [#{rt}]: pending must start at 0")

          plan = client.sync_plan
          assert_equal!(true, plan["bootstrap"], "boot [#{rt}]: sync_plan must request bootstrap")
          assert_equal!("", plan["push"], "boot [#{rt}]: sync_plan push must be empty")

          res = client.sync(ENDPOINT)
          assert_equal!(0, res[:exit], "boot [#{rt}]: sync exit must be 0")
          assert_equal!(0, res[:pending], "boot [#{rt}]: pending must be 0 after empty bootstrap")
          assert_equal!(true, client.sync_state[:bootstrapped], "boot [#{rt}]: must be bootstrapped after sync")
        end

        assert_converged!(clients, label: "boot_and_config_32bit_safety")
      end

      # 2. Model & controller CRUD (GET/POST/PATCH/DELETE via _method) + outbox sync.
      def scenario_controller_crud_and_outbox_sync
        clients = spawn_clients("crud")
        converge_all!(clients, rounds: 1)

        created_ids = {}
        clients.each do |rt, client|
          title = "Parity issue from #{rt}"
          post_res = client.request("POST", "/todo/issues", body: URI.encode_www_form("issue[title]" => title))
          assert_true!([200, 302, 303].include?(post_res[:status]), "crud [#{rt}]: POST /todo/issues returned #{post_res[:status]}")

          index_res = client.request("GET", "/todo")
          assert_equal!(200, index_res[:status], "crud [#{rt}]: GET /todo status")
          assert_true!(index_res[:body].include?(title), "crud [#{rt}]: GET /todo body missing #{title.inspect}")

          plan = client.sync_plan
          refute_empty = !plan["push"].to_s.empty?
          assert_true!(refute_empty, "crud [#{rt}]: sync_plan must carry queued create mutation")
          assert_equal!(1, client.sync_state[:pending], "crud [#{rt}]: pending must be 1 before sync")

          snap = client.snapshot_state(model_names: MODELS)
          created = snap[:tables]["Issue"].find { |r| r["title"] == title }
          assert_true!(!created.nil?, "crud [#{rt}]: created Issue missing from local SQLite")
          created_ids[rt] = created["id"]

          # PATCH via Rails form _method=patch.
          patch_res = client.request("POST", "/todo/issues/#{created['id']}", body: URI.encode_www_form("_method" => "patch", "done" => "1"))
          assert_true!([200, 302, 303].include?(patch_res[:status]), "crud [#{rt}]: PATCH returned #{patch_res[:status]}")

          client.sync(ENDPOINT)
        end

        # All runtimes now pull each other's issues and converge.
        converge_all!(clients, rounds: 2)
        snaps = assert_converged!(clients, label: "crud_after_create_and_patch")
        assert_equal!(clients.size, snaps.values.first[:tables]["Issue"].size, "crud: all clients' issues must be present")
        snaps.values.first[:tables]["Issue"].each do |row|
          assert_equal!("done", row["state"], "crud: PATCH state=done must converge on #{row['id']}")
        end

        # DELETE via _method=delete from the first runtime and verify convergence everywhere.
        first_rt = clients.keys.first
        victim_id = created_ids[first_rt]
        del_res = clients[first_rt].request("POST", "/todo/issues/#{victim_id}", body: URI.encode_www_form("_method" => "delete"))
        assert_true!([200, 302, 303].include?(del_res[:status]), "crud [#{first_rt}]: DELETE returned #{del_res[:status]}")

        converge_all!(clients, rounds: 2)
        snaps_after = assert_converged!(clients, label: "crud_after_delete")
        assert_equal!(clients.size - 1, snaps_after.values.first[:tables]["Issue"].size, "crud: deleted issue must be gone everywhere")
      end

      # 3. Server-only validation rejection ("reject me") & rollback alongside a valid write.
      def scenario_server_only_validation_rejection_rollback
        clients = spawn_clients("reject")
        converge_all!(clients, rounds: 1)

        clients.each do |rt, client|
          client.local_write(model: "Issue", operation: "create", attributes: { "title" => "reject me" })
          client.local_write(model: "Issue", operation: "create", attributes: { "title" => "keep from #{rt}" })
          assert_equal!(2, client.sync_state[:pending], "reject [#{rt}]: both writes must queue optimistically")

          res = client.sync(ENDPOINT)
          assert_equal!(0, res[:pending], "reject [#{rt}]: rejected mutation must not jam the outbox")
        end

        converge_all!(clients, rounds: 2)
        snaps = assert_converged!(clients, label: "server_only_validation_rejection")
        titles = snaps.values.first[:tables]["Issue"].map { |r| r["title"] }
        assert_true!(!titles.include?("reject me"), "reject: 'reject me' must be rolled back everywhere")
        clients.each_key do |rt|
          assert_true!(titles.include?("keep from #{rt}"), "reject: valid write from #{rt} must survive")
        end
      end

      # 4. 32-bit signed integer boundary values (wasm32 INT32_MAX = 2_147_483_647).
      def scenario_int32_boundary_values
        boundary_title = "int32 [#{INT32_MIN}, #{INT32_MAX}, #{INT32_MAX + 1}, 9223372036854775807]"
        seeded = @server.seed_boundary_record(
          model_name: "Issue",
          id: "int32-bootstrap-row",
          title: boundary_title,
          server_version: INT32_MAX - 1,
          cursor_id: INT32_MAX - 1
        )
        assert_equal!(INT32_MAX - 1, seeded[:change].id, "int32: server seed cursor must equal INT32_MAX - 1")

        clients = spawn_clients("int32")
        clients.each do |rt, client|
          res = client.sync(ENDPOINT)
          assert_equal!(0, res[:exit], "int32 [#{rt}]: bootstrap sync exit must be 0")
          assert_equal!(INT32_MAX - 1, client.sync_state[:cursor], "int32 [#{rt}]: cursor must preserve INT32_MAX - 1")
        end
        assert_converged!(clients, label: "int32_after_bootstrap")

        # Now stream an SSE event right at INT32_MAX (2_147_483_647) for both id and version.
        updated_stamp = (Time.now.utc + 5).iso8601(InstantRecord::TIME_PRECISION)
        max_row = @server.seed_boundary_record(
          model_name: "Issue",
          id: "int32-max-stream-row",
          title: "max int32 cursor & version",
          server_version: INT32_MAX,
          cursor_id: INT32_MAX,
          updated_at: Time.parse(updated_stamp)
        )
        sse_payload = JSON.generate(
          "type" => "Issue",
          "id" => max_row[:record].id,
          "operation" => "create",
          "version" => INT32_MAX,
          "attributes" => InstantRecord.wire_attributes(max_row[:record].attributes)
        )
        frame = "id: #{INT32_MAX}\nevent: change\ndata: #{sse_payload}\n\n"

        clients.each do |rt, client|
          res = client.consume_stream(frame)
          assert_equal!(1, res[:applied], "int32 [#{rt}]: INT32_MAX SSE frame must apply")
          assert_equal!(INT32_MAX, res[:cursor], "int32 [#{rt}]: cursor must equal INT32_MAX without overflow")
          assert_equal!(INT32_MAX, client.sync_state[:cursor], "int32 [#{rt}]: persisted cursor must equal INT32_MAX")
        end

        snaps = assert_converged!(clients, label: "int32_after_max_stream")
        row = snaps.values.first[:tables]["Issue"].find { |r| r["id"] == "int32-max-stream-row" }
        assert_equal!(INT32_MAX, row["server_version"], "int32: server_version must round-trip INT32_MAX")
      end

      # 5. Identity scoping, switch (ada -> ben), event: reset, scoped purge vs unscoped survival.
      def scenario_identity_scoping_switch_and_reset
        @server.server_write(model_name: "AuthNote", operation: "create", id: "n-everyone", attributes: { title: "Public note", body: "all", audience: "everyone", owner_id: "ada" })
        @server.server_write(model_name: "AuthNote", operation: "create", id: "n-members", attributes: { title: "Members note", body: "team", audience: "members", owner_id: "ben" })
        @server.server_write(model_name: "AuthNote", operation: "create", id: "n-admins", attributes: { title: "Payroll", body: "secret", audience: "admins", owner_id: "ada" })
        @server.server_write(model_name: "AuthNote", operation: "create", id: "n-ada", attributes: { title: "Ada private", body: "mine", audience: "owner", owner_id: "ada" })
        @server.server_write(model_name: "AuthNote", operation: "create", id: "n-ben", attributes: { title: "Ben private", body: "mine", audience: "owner", owner_id: "ben" })
        @server.server_write(model_name: "Issue", operation: "create", id: "i-shared", attributes: { title: "Shared unscoped issue", state: "open" })

        clients = spawn_clients("ident", identity: "ada")
        converge_all!(clients, rounds: 1)
        snaps_ada = assert_converged!(clients, identity: "ada", label: "identity_as_ada")
        ada_note_ids = snaps_ada.values.first[:tables]["AuthNote"].map { |r| r["id"] }
        assert_equal!(%w[n-ada n-admins n-everyone n-members], ada_note_ids, "identity: ada must see public, members, admins, and own")

        # Queue one scoped AuthNote and one unscoped Issue while offline, then switch identity to ben.
        clients.each do |rt, client|
          @network.set_partition(client.id, :offline)
          client.local_write(model: "AuthNote", operation: "create", attributes: { title: "Ada queued #{rt}", body: "queued", audience: "owner", owner_id: "ada" })
          client.local_write(model: "Issue", operation: "create", attributes: { title: "Unscoped queued #{rt}" })
          assert_equal!(2, client.sync_state[:pending], "identity [#{rt}]: 2 writes must be queued")

          @network.set_identity(client.id, "ben")
          @network.set_partition(client.id, :online)
        end

        # First sync receives rejection for stale scoped write + reset event on /events;
        # follow-up sync re-bootstraps cleanly as ben while keeping unscoped Issue writes.
        converge_all!(clients, rounds: 3)
        snaps_ben = assert_converged!(clients, identity: "ben", label: "identity_after_switch_to_ben")

        ben_note_ids = snaps_ben.values.first[:tables]["AuthNote"].map { |r| r["id"] }
        assert_equal!(%w[n-ben n-everyone n-members], ben_note_ids, "identity: ben must not see admin or ada-private notes")

        issue_titles = snaps_ben.values.first[:tables]["Issue"].map { |r| r["title"] }
        clients.each_key do |rt|
          assert_true!(issue_titles.include?("Unscoped queued #{rt}"), "identity: unscoped Issue from #{rt} must survive reset")
        end
      end

      # 6. Mid-bootstrap abort (network_drop, server_503, truncated_body) + idempotent retry.
      def scenario_mid_bootstrap_abort_and_idempotent_retry
        @server.server_write(model_name: "Issue", operation: "create", id: "boot-1", attributes: { title: "Server row 1" })
        @server.server_write(model_name: "Issue", operation: "create", id: "boot-2", attributes: { title: "Server row 2" })

        %i[network_drop server_503 truncated_body].each do |abort_mode|
          clients = spawn_clients("abort_#{abort_mode}")
          clients.each do |rt, client|
            # Queue a local write before bootstrap has ever succeeded.
            client.local_write(model: "Issue", operation: "create", attributes: { title: "Pre-boot #{abort_mode} #{rt}" })
            @network.arm_bootstrap_abort(client.id, abort_mode)

            client.sync(ENDPOINT)
            state = client.sync_state
            assert_equal!(false, state[:bootstrapped], "abort(#{abort_mode}) [#{rt}]: must remain unbootstrapped after aborted bootstrap")
          end

          # Retry now that the one-shot abort cleared: must bootstrap idempotently & converge.
          converge_all!(clients, rounds: 2)
          assert_converged!(clients, label: "mid_bootstrap_abort_#{abort_mode}")
        end
      end

      # 7. Split SSE chunk framing (including multibyte UTF-8) & echo suppression.
      def scenario_split_sse_framing_and_echo_suppression
        clients = spawn_clients("sse")
        converge_all!(clients, rounds: 1)

        stamp = Time.now.utc.iso8601(InstantRecord::TIME_PRECISION)
        seeded = @server.server_write(
          model_name: "Issue",
          operation: "create",
          id: "sse-split-1",
          attributes: { title: "café — split frame", state: "open", created_at: Time.parse(stamp), updated_at: Time.parse(stamp) }
        )
        cursor = @server.current_cursor
        payload = JSON.generate(
          "type" => "Issue",
          "id" => seeded.id,
          "operation" => "create",
          "version" => seeded.server_version,
          "attributes" => InstantRecord.wire_attributes(seeded.attributes)
        )
        frame = "id: #{cursor}\nevent: change\ndata: #{payload}\n\n"
        part1 = frame[0, 17]
        part2 = frame[17, 29]
        part3 = frame[46..]

        clients.each do |rt, client|
          r1 = client.consume_stream(part1)
          assert_equal!(0, r1[:applied], "sse [#{rt}]: partial chunk 1 must apply 0")
          r2 = client.consume_stream(part2)
          assert_equal!(0, r2[:applied], "sse [#{rt}]: partial chunk 2 must apply 0")
          r3 = client.consume_stream(part3)
          assert_equal!(1, r3[:applied], "sse [#{rt}]: final chunk must apply 1")
          assert_equal!(cursor, r3[:cursor], "sse [#{rt}]: cursor must advance to #{cursor}")
          assert_equal!(true, r3[:notified], "sse [#{rt}]: genuine remote change must notify")
          assert_equal!([{ type: "Issue", id: "sse-split-1" }], r3[:changes], "sse [#{rt}]: notice must list Issue:sse-split-1")

          # Echo suppression: re-applying the exact same row with equal updated_at changes nothing.
          echo_frame = "id: #{cursor + 1}\nevent: change\ndata: #{payload}\n\n"
          echo = client.consume_stream(echo_frame)
          assert_equal!(0, echo[:applied], "sse [#{rt}]: identical echo must apply 0")
          assert_equal!(false, echo[:notified], "sse [#{rt}]: identical echo must stay quiet")
          assert_equal!(cursor + 1, echo[:cursor], "sse [#{rt}]: cursor still advances past echoed event")
        end

        assert_converged!(clients, label: "split_sse_framing_and_echo_suppression")
      end

      # 8. Exercise frontend/http.js (`write` and `localHttpClient.request`) directly
      # against live AppHost#request in Node.
      def scenario_frontend_http_compiled_fetch_path
        wasm_driver = @drivers[:wasm]
        @network.register_client("frontend_http_wasm")
        client = wasm_driver.create_client("frontend_http_wasm")
        client.sync(ENDPOINT)

        res = client.verify_frontend_http
        assert_equal!(true, res["ok"], "frontend/http.js: verify_frontend_http must succeed")
        assert_equal!(true, res["containsWrittenTitle"], "frontend/http.js: write() POST must persist to AppHost SQLite")

        # What the frontend sends: these two requests, with these headers and nothing added to the address.
        sent = res["calls"].map { |call| call.slice("method", "path", "headers") }
        expected = [
          {
            "method" => "POST", "path" => "/todo/issues",
            "headers" => { "x-requested-with" => "XMLHttpRequest", "x-xsrf-token" => "test-csrf-token" }
          },
          {
            "method" => "GET", "path" => "/email?member=maya&inbox=support",
            "headers" => {
              "accept" => "text/html, application/xhtml+xml",
              "x-inertia" => "true",
              "x-inertia-partial-component" => "Email/Inbox",
              "x-inertia-partial-data" => "mail",
              "x-requested-with" => "XMLHttpRequest"
            }
          }
        ]
        assert_equal!(expected, sent, "frontend/http.js: write() and localHttpClient must send their headers")

        # What the compiled app answers: the page object, with the one prop the headers asked for.
        page = res["page"]
        assert_equal!(200, page["status"], "frontend/http.js: localHttpClient GET must return 200")
        assert_equal!("true", page["headers"]["x-inertia"], "frontend/http.js: the compiled app must answer X-Inertia with a page object")
        assert_true!(page["headers"]["content-type"].to_s.start_with?("application/json"), "frontend/http.js: the page object must be JSON")
        object = JSON.parse(page["data"])
        assert_equal!("Email/Inbox", object["component"], "frontend/http.js: page object component")
        assert_equal!(%w[errors mail], object["props"].keys.sort, "frontend/http.js: a partial reload must carry only the props it names")

        client.sync(ENDPOINT)
        assert_converged!({ wasm: client }, label: "frontend_http_compiled_fetch_path")
      end
    end
  end
end
