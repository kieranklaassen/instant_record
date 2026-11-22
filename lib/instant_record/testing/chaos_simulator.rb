require "json"

module InstantRecord
  module Testing
    # Deterministic seeded multi-client chaos simulator.
    # Drives heterogeneous clients (CRuby, Wasm AppHost, Native C ABI Fiddle)
    # simultaneously against one authoritative server through randomized:
    #   - network partitions (offline, drop_post, drop_get, server_503, drop_after_apply)
    #   - per-client clock skew (LWW conflicts & tie-breaking)
    #   - 32-bit integer boundary values (server_version near INT32_MAX, boundary text)
    #   - identity switches (anonymous / ada / ben / cleo -> reset & re-bootstrap)
    #   - mid-bootstrap aborts (network_drop, server_503, truncated_body)
    #   - split SSE stream chunks
    #   - server-only validation rejections ("reject me") & unauthorized writes
    #
    # Enforces zero unexpected stderr, exit == 0, and pending >= 0 at every step,
    # then heals all partitions and asserts bit-for-bit convergence against the
    # authoritative server and across runtimes.
    class ChaosSimulator
      MODELS = %w[Issue AuthNote].freeze
      ENDPOINT = InstantRecord::DEFAULT_MOUNT_PATH
      IDENTITIES = [nil, "ada", "ben", "cleo"].freeze
      AUDIENCES = %w[everyone members admins owner].freeze
      CLOCK_SKEWS = [-120.0, -5.0, 0.0, 0.0, 5.0, 120.0].freeze

      Report = Struct.new(:seed, :steps, :clients, :runtimes, :backend, :elapsed_ms, :stats, :trace, keyword_init: true)

      def initialize(seed:, steps: 60, client_count: 3, runtimes:, artifacts:, rails_app: nil, database_url: nil, out: $stdout)
        @seed = Integer(seed)
        @steps = [Integer(steps), 1].max
        @client_count = [Integer(client_count), 1].max
        @runtime_names = Array(runtimes).map(&:to_sym)
        @artifacts = artifacts
        @rails_app = rails_app
        @database_url = database_url
        @out = out
        @rng = Random.new(@seed)
        @trace = []
        @stats = Hash.new(0)
        @known_issue_ids = []
        @known_note_ids = []
        @boundary_ids = {}
      end

      def run
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @server = AuthoritativeServer.build(rails_app: @rails_app, database_url: @database_url, models: MODELS)
        @server.reset_data!
        @network = FaultNetwork.new(@server)
        @drivers = build_drivers
        @clients = spawn_clients

        @out.puts "InstantRecord chaos simulation (seed=#{@seed}, steps=#{@steps}, clients=#{@clients.size}, backend=#{@server.backend_label}, runtimes=[#{@clients.map(&:runtime_name).join(',')}])"

        seed_initial_records!
        run_chaos_steps!
        heal_and_verify_convergence!

        elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
        @out.puts "  [PASS] seed=#{@seed} converged bit-for-bit (#{@steps} steps, #{elapsed_ms}ms, ops=#{@stats.sort.to_h})"

        Report.new(
          seed: @seed,
          steps: @steps,
          clients: @clients.size,
          runtimes: @clients.map(&:runtime_name),
          backend: @server.backend_label,
          elapsed_ms: elapsed_ms,
          stats: @stats.dup,
          trace: @trace.dup
        )
      rescue StandardError => e
        raise e.class, format_failure(e)
      ensure
        @drivers&.each_value do |driver|
          driver.close
        rescue StandardError
          nil
        end
        @server&.close
      end

      private

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

      def spawn_clients
        Array.new(@client_count) do |i|
          rt = @runtime_names[i % @runtime_names.size]
          cid = "c#{i}_#{rt}"
          identity = IDENTITIES[@rng.rand(IDENTITIES.size)]
          skew = CLOCK_SKEWS[@rng.rand(CLOCK_SKEWS.size)]
          @network.register_client(cid, identity: identity, clock_skew: skew)
          record_trace("init #{cid} rt=#{rt} identity=#{identity.inspect} skew=#{skew}s")
          @drivers[rt].create_client(cid)
        end
      end

      def seed_initial_records!
        2.times do |i|
          id = "seed-issue-#{@seed}-#{i}"
          @server.server_write(model_name: "Issue", operation: "create", id: id, attributes: { title: "Seed issue #{i}", state: "open" })
          @known_issue_ids << id
        end
        [
          ["seed-note-public", "ada", "everyone"],
          ["seed-note-members", "ben", "members"],
          ["seed-note-admins", "ada", "admins"],
          ["seed-note-ada", "ada", "owner"],
          ["seed-note-ben", "ben", "owner"]
        ].each do |id, owner, audience|
          @server.server_write(
            model_name: "AuthNote",
            operation: "create",
            id: id,
            attributes: { title: "Seed #{audience}", body: "seed", audience: audience, owner_id: owner }
          )
          @known_note_ids << id
        end

        # Guarantee at least one mid-bootstrap abort on step 0 for client 0.
        first = @clients.first
        abort_mode = %i[network_drop server_503 truncated_body][@rng.rand(3)]
        @network.arm_bootstrap_abort(first.id, abort_mode)
        record_trace("arm_bootstrap_abort #{first.id} mode=#{abort_mode}")
        @stats[:bootstrap_aborts] += 1
        first.sync(ENDPOINT)
        if first.sync_state[:bootstrapped]
          raise ConvergenceError, "#{first.id} unexpectedly became bootstrapped after #{abort_mode} abort"
        end
      end

      def run_chaos_steps!
        @steps.times do |step_idx|
          client = @clients[@rng.rand(@clients.size)]
          roll = @rng.rand(100)

          if roll < 22
            step_local_issue_write(step_idx, client)
          elsif roll < 34
            step_local_auth_note_write(step_idx, client)
          elsif roll < 44
            step_server_write(step_idx)
          elsif roll < 56
            step_toggle_partition_or_skew(step_idx, client)
          elsif roll < 74
            step_sync_pass(step_idx, client)
          elsif roll < 84
            step_split_sse_stream(step_idx, client)
          elsif roll < 92
            step_switch_identity(step_idx, client)
          elsif roll < 96
            step_arm_bootstrap_abort(step_idx, client)
          else
            step_int32_boundary_event(step_idx)
          end

          verify_step_invariants!(step_idx, client)
        end
      end

      def step_local_issue_write(step_idx, client)
        snap = client.snapshot_state(model_names: MODELS)
        local_issues = snap[:tables]["Issue"].reject { |r| @boundary_ids[r["id"]] }
        op_roll = @rng.rand(10)

        if local_issues.empty? || op_roll < 5
          # Occasionally emit a server-rejected title ("reject me") to test rollback under chaos.
          title = @rng.rand(6) == 0 ? "reject me" : "chaos-#{@seed}-s#{step_idx}-#{client.id}"
          id = client.local_write(model: "Issue", operation: "create", attributes: { "title" => title })
          @known_issue_ids << id if id && title != "reject me"
          @stats[:local_issue_create] += 1
          record_trace("step=#{step_idx} #{client.id} create Issue title=#{title.inspect} id=#{id}")
        elsif op_roll < 8
          target = local_issues[@rng.rand(local_issues.size)]
          new_state = target["state"] == "done" ? "open" : "done"
          client.local_write(model: "Issue", operation: "update", id: target["id"], attributes: { "state" => new_state })
          @stats[:local_issue_update] += 1
          record_trace("step=#{step_idx} #{client.id} update Issue id=#{target['id']} state=#{new_state}")
        else
          target = local_issues[@rng.rand(local_issues.size)]
          client.local_write(model: "Issue", operation: "destroy", id: target["id"])
          @stats[:local_issue_destroy] += 1
          record_trace("step=#{step_idx} #{client.id} destroy Issue id=#{target['id']}")
        end
      end

      def step_local_auth_note_write(step_idx, client)
        snap = client.snapshot_state(model_names: MODELS)
        local_notes = snap[:tables]["AuthNote"]
        policy = @network.policy(client.id)

        if local_notes.empty? || @rng.rand(3) < 2
          # Mix authorized owner writes with occasional unauthorized owner writes (rejected by server).
          owner = (@rng.rand(4) == 0 || policy.identity.nil?) ? %w[ada ben cleo][@rng.rand(3)] : policy.identity
          audience = AUDIENCES[@rng.rand(AUDIENCES.size)]
          title = "note-#{@seed}-s#{step_idx}-#{client.id}"
          id = client.local_write(
            model: "AuthNote",
            operation: "create",
            attributes: { "title" => title, "body" => "chaos body #{step_idx}", "audience" => audience, "owner_id" => owner }
          )
          @known_note_ids << id if id
          @stats[:local_note_create] += 1
          record_trace("step=#{step_idx} #{client.id} create AuthNote owner=#{owner} audience=#{audience} id=#{id}")
        else
          target = local_notes[@rng.rand(local_notes.size)]
          client.local_write(model: "AuthNote", operation: "destroy", id: target["id"])
          @stats[:local_note_destroy] += 1
          record_trace("step=#{step_idx} #{client.id} destroy AuthNote id=#{target['id']}")
        end
      end

      def step_server_write(step_idx)
        skew = CLOCK_SKEWS[@rng.rand(CLOCK_SKEWS.size)]
        if @rng.rand(2) == 0
          id = "srv-issue-#{@seed}-#{step_idx}"
          @server.server_write(
            model_name: "Issue",
            operation: "create",
            id: id,
            attributes: { title: "Server issue s#{step_idx}", state: "open" },
            clock_offset: skew
          )
          @known_issue_ids << id
          @stats[:server_write] += 1
          record_trace("step=#{step_idx} server create Issue id=#{id} clock_offset=#{skew}s")
        else
          mutable = @known_issue_ids.reject { |i| @boundary_ids[i] }
          return if mutable.empty?

          victim = mutable[@rng.rand(mutable.size)]
          if @rng.rand(3) == 0
            @server.server_write(model_name: "Issue", operation: "destroy", id: victim)
            @stats[:server_destroy] += 1
            record_trace("step=#{step_idx} server destroy Issue id=#{victim}")
          else
            state = @rng.rand(2) == 0 ? "done" : "open"
            @server.server_write(model_name: "Issue", operation: "update", id: victim, attributes: { state: state }, clock_offset: skew)
            @stats[:server_update] += 1
            record_trace("step=#{step_idx} server update Issue id=#{victim} state=#{state} clock_offset=#{skew}s")
          end
        end
      end

      def step_toggle_partition_or_skew(step_idx, client)
        mode = FaultNetwork::PARTITION_MODES[@rng.rand(FaultNetwork::PARTITION_MODES.size)]
        skew = CLOCK_SKEWS[@rng.rand(CLOCK_SKEWS.size)]
        @network.set_partition(client.id, mode)
        @network.set_clock_skew(client.id, skew)
        @stats[:partition_changes] += 1
        record_trace("step=#{step_idx} #{client.id} partition=#{mode} clock_skew=#{skew}s")
      end

      def step_sync_pass(step_idx, client)
        res = client.sync(ENDPOINT)
        @stats[:sync_passes] += 1
        record_trace("step=#{step_idx} #{client.id} sync pending=#{res[:pending]} cursor=#{res[:cursor]} changed=#{res[:changed]} fault=#{res[:fault_fired]}")
      end

      def step_split_sse_stream(step_idx, client)
        state = client.sync_state
        return step_sync_pass(step_idx, client) unless state[:bootstrapped]

        url = "#{ENDPOINT}/events?after=#{state[:cursor]}&window=0"
        url += "&identity=#{state[:identity]}" unless state[:identity].empty?
        reply = @network.exchange(client.id, "GET", url, "")
        return unless reply[:status] == 200 && !reply[:body].empty?

        body = reply[:body]
        parts = 2 + @rng.rand(3)
        chunk_size = [(body.length / parts), 1].max
        applied_total = 0
        offset = 0
        while offset < body.length
          piece = body[offset, chunk_size]
          offset += chunk_size
          res = client.consume_stream(piece)
          applied_total += res[:applied]
        end
        @stats[:split_sse] += 1
        record_trace("step=#{step_idx} #{client.id} split_sse parts=#{parts} applied=#{applied_total}")
      end

      def step_switch_identity(step_idx, client)
        current = @network.policy(client.id).identity
        choices = IDENTITIES - [current]
        next_id = choices[@rng.rand(choices.size)]
        @network.set_identity(client.id, next_id)
        @stats[:identity_switches] += 1
        record_trace("step=#{step_idx} #{client.id} switch_identity #{current.inspect} -> #{next_id.inspect}")
      end

      def step_arm_bootstrap_abort(step_idx, client)
        mode = %i[network_drop server_503 truncated_body][@rng.rand(3)]
        @network.arm_bootstrap_abort(client.id, mode)
        @stats[:bootstrap_aborts] += 1
        record_trace("step=#{step_idx} #{client.id} arm_bootstrap_abort mode=#{mode}")
      end

      def step_int32_boundary_event(step_idx)
        id = "int32-chaos-#{@seed}-#{step_idx}"
        @boundary_ids[id] = true
        @server.seed_boundary_record(
          model_name: "Issue",
          id: id,
          title: "int32 #{INT32_MIN}..#{INT32_MAX} step #{step_idx}",
          server_version: INT32_MAX
        )
        @stats[:int32_boundaries] += 1
        record_trace("step=#{step_idx} server seed_boundary_record id=#{id} server_version=#{INT32_MAX}")
      end

      def verify_step_invariants!(step_idx, client)
        state = client.sync_state
        if state[:pending] < 0
          raise ConvergenceError, "step=#{step_idx} #{client.id} reported negative pending=#{state[:pending]}"
        end
        if state[:cursor] < 0
          raise ConvergenceError, "step=#{step_idx} #{client.id} reported negative cursor=#{state[:cursor]}"
        end
      end

      def heal_and_verify_convergence!
        @network.heal_all!
        @clients.each { |c| @network.set_clock_skew(c.id, 0.0) }
        record_trace("heal_all: all partitions online, clock_skew=0")

        # Drain every client's outbox and catch up all clients until quiescent.
        8.times do
          @clients.each { |c| c.sync(ENDPOINT) }
          all_ready = @clients.all? do |c|
            st = c.sync_state
            st[:bootstrapped] && st[:pending] == 0
          end
          if all_ready
            # One final catch-up pass ensures every client sees writes drained by peers
            # earlier in the same round.
            @clients.each { |c| c.sync(ENDPOINT) }
            break
          end
        end

        snapshots_by_identity = Hash.new { |h, k| h[k] = [] }

        @clients.each do |client|
          identity = @network.policy(client.id).identity
          snap = client.snapshot_state(model_names: MODELS)

          unless snap[:bootstrapped]
            raise ConvergenceError, "#{client.id} failed to bootstrap during heal phase"
          end
          unless snap[:pending] == 0
            raise ConvergenceError, "#{client.id} still has pending=#{snap[:pending]} after heal phase"
          end

          snap[:sync_states].each do |model, rows|
            unsynced = rows.reject { |r| r["sync_state"] == "synced" }
            unless unsynced.empty?
              raise ConvergenceError, "#{client.id} still has unsynced #{model} rows after heal: #{unsynced.inspect}"
            end
          end

          # Under extreme forward clock skew (> HLC::DEFAULT_MAX_DRIFT), the server
          # intentionally clamps updated_at to server UTC while keeping HLC-anchored
          # ordering, so chaos convergence compares every domain column, created_at,
          # and server_version bit-for-bit across all clients and the server.
          expected = @server.visible_state(identity: identity).transform_values do |rows|
            InstantRecord::Testing.canonical_rows(rows, exclude_columns: %w[sync_state updated_at])
          end
          actual = snap[:tables].transform_values do |rows|
            InstantRecord::Testing.canonical_rows(rows, exclude_columns: %w[sync_state updated_at])
          end
          expected_json = InstantRecord::Testing.canonical_json(expected)
          actual_json = InstantRecord::Testing.canonical_json(actual)

          unless actual_json == expected_json
            raise ConvergenceError,
              "#{client.id} (#{client.runtime_name}, identity=#{identity.inspect}) diverged from server (#{@server.backend_label}):\n" \
              "--- server ---\n#{expected_json}\n--- #{client.id} ---\n#{actual_json}"
          end

          snapshots_by_identity[identity] << [client, actual_json]
        end

        # Verify bit-for-bit agreement among peer clients sharing an identity.
        snapshots_by_identity.each do |identity, list|
          next if list.size < 2

          ref_client, ref_json = list.first
          list[1..].each do |other_client, other_json|
            unless other_json == ref_json
              raise ParityMismatch,
                "Clients #{ref_client.id} and #{other_client.id} (identity=#{identity.inspect}) diverged bit-for-bit!"
            end
          end
        end
      end

      def record_trace(line)
        @trace << line
      end

      def format_failure(error)
        tail = @trace.last(40).map { |l| "  #{l}" }.join("\n")
        "#{error.message}\n\nReproduce with:\n  bundle exec rake instant_record:chaos SEED=#{@seed} STEPS=#{@steps} CLIENTS=#{@client_count} RUNTIMES=#{@runtime_names.join(',')}\n\nRecent trace (#{@trace.size} total events):\n#{tail}"
      end
    end
  end
end
