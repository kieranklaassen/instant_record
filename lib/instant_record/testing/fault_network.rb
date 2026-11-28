require "json"

module InstantRecord
  module Testing
    # Deterministic network fault injector wrapping an AuthoritativeServer.
    # Controls per-client network partitions, asymmetric drops, post-commit ack
    # drops (for idempotency verification), one-shot mid-bootstrap aborts,
    # identity assignments, and per-client clock skew.
    class FaultNetwork
      PARTITION_MODES = %i[online offline drop_post drop_get server_503 drop_after_apply].freeze
      BOOTSTRAP_ABORT_MODES = %i[network_drop server_503 truncated_body].freeze

      ClientPolicy = Struct.new(:partition, :identity, :clock_skew, :bootstrap_abort, keyword_init: true)

      ExchangeRecord = Struct.new(:client_id, :method, :url, :status, :fault, :identity, keyword_init: true)

      attr_reader :server, :log

      def initialize(server)
        @server = server
        @policies = {}
        @log = []
        @fault_fired_in_window = false
      end

      def register_client(client_id, identity: nil, clock_skew: 0.0, partition: :online)
        @policies[client_id.to_s] = ClientPolicy.new(
          partition: validate_partition_mode!(partition),
          identity: identity,
          clock_skew: clock_skew.to_f,
          bootstrap_abort: nil
        )
      end

      def policy(client_id)
        @policies[client_id.to_s] ||= ClientPolicy.new(partition: :online, identity: nil, clock_skew: 0.0, bootstrap_abort: nil)
      end

      def set_partition(client_id, mode)
        sym = validate_partition_mode!(mode)
        policy(client_id).partition = sym
      end

      def set_identity(client_id, identity)
        policy(client_id).identity = identity
      end

      def set_clock_skew(client_id, seconds)
        policy(client_id).clock_skew = seconds.to_f
      end

      # One-shot mid-bootstrap abort: :network_drop (status 0), :server_503 (503),
      # or :truncated_body (200 with truncated invalid JSON).
      def arm_bootstrap_abort(client_id, mode = :network_drop)
        sym = validate_bootstrap_abort_mode!(mode)
        policy(client_id).bootstrap_abort = sym
      end

      def heal_all!
        @policies.each_value do |pol|
          pol.partition = :online
          pol.bootstrap_abort = nil
        end
      end

      def track_faults
        previous = @fault_fired_in_window
        @fault_fired_in_window = false
        result = yield
        [result, @fault_fired_in_window]
      ensure
        @fault_fired_in_window = previous || @fault_fired_in_window
      end

      # Synchronous exchange invoked by CRuby, Wasm (Node AppHost), or Native (Fiddle).
      def exchange(client_id, method, url, body = "")
        pol = policy(client_id)
        verb = method.to_s.upcase
        path = url.to_s

        # 1. One-shot mid-bootstrap abort takes precedence on /bootstrap.
        if verb == "GET" && path.include?("/bootstrap") && pol.bootstrap_abort
          abort_mode = pol.bootstrap_abort
          pol.bootstrap_abort = nil
          @fault_fired_in_window = true
          return record_exchange(client_id, verb, path, pol.identity, fault: :"bootstrap_#{abort_mode}") do
            case abort_mode
            when :network_drop then { status: 0, body: "" }
            when :server_503 then { status: 503, body: "Service Unavailable" }
            when :truncated_body then { status: 200, body: '{"cursor":99,"records":[{"type":"Issue","id":"half' }
            else { status: 0, body: "" }
            end
          end
        end

        # 2. Partition rules.
        case pol.partition
        when :offline
          @fault_fired_in_window = true
          return record_exchange(client_id, verb, path, pol.identity, fault: :offline) { { status: 0, body: "" } }
        when :drop_post
          if verb == "POST"
            @fault_fired_in_window = true
            return record_exchange(client_id, verb, path, pol.identity, fault: :drop_post) { { status: 0, body: "" } }
          end
        when :drop_get
          if verb == "GET"
            @fault_fired_in_window = true
            return record_exchange(client_id, verb, path, pol.identity, fault: :drop_get) { { status: 0, body: "" } }
          end
        when :server_503
          @fault_fired_in_window = true
          return record_exchange(client_id, verb, path, pol.identity, fault: :server_503) { { status: 503, body: "Service Unavailable" } }
        when :drop_after_apply
          if verb == "POST" && path.include?("/mutations")
            # Server applies and commits the batch, then the response is dropped
            # before reaching the client. The client must retry the same mutation_id
            # and receive the idempotent ledger replay without duplicating state.
            @server.exchange(verb, path, body, identity: pol.identity)
            pol.partition = :online
            @fault_fired_in_window = true
            return record_exchange(client_id, verb, path, pol.identity, fault: :drop_after_apply) { { status: 0, body: "" } }
          end
        end

        reply = @server.exchange(verb, path, body, identity: pol.identity)
        @log << ExchangeRecord.new(client_id: client_id.to_s, method: verb, url: path, status: reply[:status], fault: nil, identity: pol.identity)
        { status: reply[:status], body: reply[:body].to_s }
      end

      private

      def validate_partition_mode!(mode)
        sym = mode.respond_to?(:to_sym) ? mode.to_sym : nil
        raise ArgumentError, "Unknown partition mode: #{mode.inspect}" unless PARTITION_MODES.include?(sym)

        sym
      end

      def validate_bootstrap_abort_mode!(mode)
        sym = mode.respond_to?(:to_sym) ? mode.to_sym : nil
        raise ArgumentError, "Unknown bootstrap abort mode: #{mode.inspect}" unless BOOTSTRAP_ABORT_MODES.include?(sym)

        sym
      end

      def record_exchange(client_id, verb, path, identity, fault:)
        reply = yield
        @log << ExchangeRecord.new(client_id: client_id.to_s, method: verb, url: path, status: reply[:status], fault: fault, identity: identity)
        reply
      end
    end
  end
end
