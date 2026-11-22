require "securerandom"

module InstantRecord
  # Raised by a sync_action to reject a mutation with a clean domain reason.
  # Rolls back the transaction on both client and server; on the server,
  # MutationApplier returns the message in the rejection payload.
  class MutationRejected < StandardError; end

  # Declarative dual-runtime transactional custom mutators (`sync_action`).
  #
  # A model declares a mutator with `sync_action :action_name` backed by
  # `def self.action_name(args)` (or keyword arguments) and invokes it through
  # `Model.perform_sync_action(:action_name, args)` or
  # `InstantRecord.mutate("Model.action_name", args)`.
  #
  # - In the browser runtime, the mutator runs inside a SQLite savepoint,
  #   suppresses per-row outbox mutations, captures local rollback snapshots,
  #   and queues a single `{ mutator, args, mutation_id }` outbox intent.
  # - On the server runtime, direct calls run in one transaction with normal
  #   server change logging; replayed intents run inside MutationApplier's
  #   transaction with AppliedMutation idempotency, unified SyncScope + action
  #   authorization, commit-guarded ActiveJob enqueueing, and rollback payloads.
  # - In compiled Spinel builds, EntryBuilder generates a static `case`
  #   dispatcher for `SyncActions.dispatch` (zero `send` or `constantize`).
  module SyncActions
    ACTION_NAME_PATTERN = /\A[a-z_][a-zA-Z0-9_]*[!?]?\z/

    # Pure-Ruby 32-bit-safe SHA-256 constants (FIPS 180-4) for deterministic
    # UUID derivation across CRuby and Spinel without Digest or 64-bit overflow.
    SHA256_K = [
      0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
      0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
      0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
      0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
      0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
      0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ].freeze

    SHA256_H = [
      0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
      0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ].freeze

    HEX_DIGITS = "0123456789abcdef".freeze
    MASK32 = 0xffffffff

    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      # Declare a dual-runtime custom mutator on this class.
      # In compiled builds, define `def self.<action_name>(args)` (no block).
      def sync_action(action_name, &block)
        action = action_name.to_s
        unless ACTION_NAME_PATTERN.match?(action)
          raise ArgumentError, "Invalid sync_action name: #{action_name.inspect}"
        end

        @instant_record_sync_actions ||= {}
        @instant_record_sync_actions[action] = block
        InstantRecord::SyncActions.register(self, action, block)
        action.to_sym
      end

      def instant_record_sync_actions
        @instant_record_sync_actions ||= {}
      end

      # Declare server-side authorization for one action or all actions on this
      # class. Wrap inside `server_only` in models compiled for browser/native.
      def authorize_sync_action(action_name = nil, &block)
        @instant_record_action_authorizers ||= {}
        key = action_name.nil? ? :__all__ : action_name.to_s
        @instant_record_action_authorizers[key] = block
      end

      def instant_record_action_authorizer(action_name)
        authorizers = @instant_record_action_authorizers
        return nil unless authorizers

        authorizers[action_name.to_s] || authorizers[:__all__]
      end

      # Execute a declared sync_action in the current runtime.
      def perform_sync_action(action_name, args = nil, mutation_id: nil, **kwargs)
        merged = args ? (kwargs.empty? ? args : args.merge(kwargs)) : kwargs
        InstantRecord::SyncActions.mutate("#{name}.#{action_name}", merged, mutation_id: mutation_id)
      end
    end

    # Captures local optimistic changes inside a browser SQLite savepoint so a
    # single outbox intent is queued and rejected intents can roll back cleanly.
    class ClientFrame
      attr_reader :mutation_id

      def initialize(mutation_id)
        @mutation_id = mutation_id
        @seq = 0
        @touched = {}
        @order = []
      end

      def next_uuid
        uuid = SyncActions.deterministic_uuid(@mutation_id, @seq)
        @seq += 1
        uuid
      end

      def record_create(record)
        key = "#{record.class.name}:#{record.id}"
        return if @touched.key?(key)

        @touched[key] = {
          "type" => record.class.name,
          "id" => record.id,
          "op" => "create"
        }
        @order << key
      end

      def capture_before(record, operation)
        key = "#{record.class.name}:#{record.id}"
        return if @touched.key?(key)

        before = record.attributes.dup
        if operation == "update" && record.respond_to?(:changes_to_save)
          record.changes_to_save.each do |col, pair|
            before[col.to_s] = pair[0]
          end
        end

        @touched[key] = {
          "type" => record.class.name,
          "id" => record.id,
          "op" => operation,
          "before" => SyncActions.snapshot_attributes(before)
        }
        @order << key
      end

      def touched_list
        list = []
        @order.each { |key| list << @touched[key] }
        list
      end
    end

    # --- cruby-server-frame:start ---
    # Server-only execution frame used by MutationApplier during authoritative
    # replay (and direct server calls with deterministic mutation_id).
    class ServerFrame
      attr_reader :mutation_id, :identity, :scope, :partition, :enforcing

      def initialize(mutation_id:, identity: nil, scope: nil, partition: nil, enforcing: false)
        @mutation_id = mutation_id
        @identity = identity
        @scope = scope
        @partition = partition
        @enforcing = enforcing
        @seq = 0
        @touched_refs = []
        @touched_seen = {}
        @applied_order = []
        @applied = {}
      end

      def enforcing? = @enforcing

      def next_uuid
        uuid = SyncActions.deterministic_uuid(@mutation_id, @seq)
        @seq += 1
        uuid
      end

      def note_ref(type, id)
        return if id.nil? || id.to_s.empty?

        key = "#{type}:#{id}"
        return if @touched_seen[key]

        @touched_seen[key] = true
        @touched_refs << [type, id]
      end

      def note_read(record)
        note_ref(record.class.name, record.id)
      end

      def touched_refs
        @touched_refs
      end

      def applied_records
        @applied_order.map { |key| @applied[key] }
      end

      def authorize_create!(record)
        model = record.class
        note_ref(model.name, record.id)

        if (part = model.instant_record_sync_partition)
          part_value = part.extract(@partition)
          raise MutationApplier::NotPermitted, "a partition is required" unless part_value

          col = part.column
          given = record[col].presence
          raise MutationApplier::NotPermitted, "record not in active partition" if given && given.to_s != part_value

          record[col] = part_value
        end

        if (column = model.instant_record_sync_scope)
          raise MutationApplier::NotPermitted, "a scope is required" unless @scope

          given = record[column].presence
          raise MutationApplier::NotPermitted if given && given != @scope

          record[column] = @scope
        end

        if hidden?(model, record.id)
          raise MutationApplier::NotPermitted
        end
      end

      def finalize_create!(record)
        model = record.class
        permit_writable!(model, record.id)
        log_change(record, "create")
        record_applied(model.name, record.id, {
          type: model.name,
          id: record.id,
          operation: "create",
          version: record[:server_version],
          attributes: InstantRecord.wire_attributes(record.attributes)
        })
      end

      def authorize_update_before!(record)
        model = record.class
        note_ref(model.name, record.id)

        if (part = model.instant_record_sync_partition)
          part_value = part.extract(@partition)
          raise MutationApplier::NotPermitted, "a partition is required" unless part_value

          col = part.column
          existing_part = record.attribute_in_database(col)
          raise MutationApplier::NotPermitted, "record not in active partition" if existing_part.to_s != part_value || record[col].to_s != part_value
        end

        if (column = model.instant_record_sync_scope)
          raise MutationApplier::NotPermitted, "a scope is required" unless @scope

          existing_scope = record.attribute_in_database(column)
          raise MutationApplier::NotPermitted if existing_scope != @scope || record[column] != @scope
        end

        raise MutationApplier::NotPermitted if hidden?(model, record.id)
        permit_writable!(model, record.id)
      end

      def finalize_update!(record)
        model = record.class
        permit_writable!(model, record.id)
        log_change(record, "update")
        record_applied(model.name, record.id, {
          type: model.name,
          id: record.id,
          operation: "update",
          version: record[:server_version],
          attributes: InstantRecord.wire_attributes(record.attributes)
        })
      end

      def authorize_destroy!(record)
        model = record.class
        note_ref(model.name, record.id)

        if (part = model.instant_record_sync_partition)
          part_value = part.extract(@partition)
          raise MutationApplier::NotPermitted, "a partition is required" unless part_value
          raise MutationApplier::NotPermitted, "record not in active partition" if record[part.column].to_s != part_value
        end

        if (column = model.instant_record_sync_scope)
          raise MutationApplier::NotPermitted, "a scope is required" unless @scope
          raise MutationApplier::NotPermitted if record[column] != @scope
        end

        raise MutationApplier::NotPermitted if hidden?(model, record.id)
        permit_writable!(model, record.id)
      end

      def finalize_destroy!(record)
        model = record.class
        InstantRecord::Change.create!(
          record_type: model.name,
          record_id: record.id,
          operation: "destroy",
          version: 0,
          attributes_payload: {},
          scope: InstantRecord.scope_of(record),
          partition: InstantRecord.partition_of(record)
        )
        record_applied(model.name, record.id, {
          type: model.name,
          id: record.id,
          operation: "destroy",
          version: 0,
          attributes: {}
        })
      end

      private

      def hidden?(model, id)
        model.instant_record_visibility && model.exists?(id: id) &&
          !SyncScope.visible(model, @identity, partition: @partition).exists?(id: id)
      end

      def permit_writable!(model, id)
        return unless model.instant_record_writability

        raise MutationApplier::NotPermitted unless SyncScope.writable(model, @identity, partition: @partition).exists?(id: id)
      end

      def log_change(record, operation)
        InstantRecord::Change.create!(
          record_type: record.class.name,
          record_id: record.id,
          operation: operation,
          version: record[:server_version],
          attributes_payload: InstantRecord.wire_attributes(record.attributes),
          scope: InstantRecord.scope_of(record),
          partition: InstantRecord.partition_of(record)
        )
      end

      def record_applied(type, id, payload)
        key = "#{type}:#{id}"
        @applied_order << key unless @applied.key?(key)
        @applied[key] = payload
      end
    end
    # --- cruby-server-frame:end ---

    class << self
      def client_frame
        @client_frame
      end

      def recording_client_mutator?
        !@client_frame.nil?
      end

      def active_frame
        InstantRecord.browser? ? client_frame : server_frame
      end

      # Execute a declared sync_action in the active runtime.
      def mutate(mutator_name, args = nil, mutation_id: nil, **kwargs)
        name = mutator_name.to_s
        merged = args ? (kwargs.empty? ? args : args.merge(kwargs)) : kwargs
        normalized = normalize_args(merged)

        if InstantRecord.browser?
          # Nested mutate inside an active client mutator joins the outer
          # savepoint and single outbox intent rather than splitting intents.
          if @client_frame
            return with_savepoint { dispatch(name, normalized) }
          end

          id = (mutation_id.nil? || mutation_id.to_s.empty?) ? SecureRandom.uuid : mutation_id.to_s
          owner_type = owner_type_of(name)
          frame = ClientFrame.new(id)

          with_savepoint do
            @client_frame = frame
            begin
              result = dispatch(name, normalized)
              InstantRecord::OutboxMutation.create!(
                id: id,
                record_type: owner_type,
                record_id: name,
                operation: "mutator",
                changes_payload: {
                  "mutator" => name,
                  "args" => normalized,
                  "touched" => frame.touched_list
                },
                base_version: 0
              )
              result
            ensure
              @client_frame = nil
            end
          end
        else
          execute_on_server(name, normalized, mutation_id)
        end
      end

      # GemVendor replaces this method in compiled builds with native SQLite SAVEPOINT.
      def with_savepoint(&block)
        ActiveRecord::Base.transaction(requires_new: true, &block)
      end

      # Recursively normalize mutator arguments to JSON-safe string-keyed values.
      def normalize_args(value)
        return {} if value.nil?
        unless value.is_a?(Hash)
          raise ArgumentError, "sync_action args must be a Hash"
        end

        normalize_hash(value)
      end

      # Capture full row attributes (including server_version and sync_state)
      # with microsecond timestamp precision for client rollback snapshots.
      def snapshot_attributes(attributes)
        out = {}
        attributes.each do |key, value|
          out[key.to_s] = value.respond_to?(:usec) ? value.iso8601(InstantRecord::TIME_PRECISION) : value
        end
        out
      end

      def owner_type_of(mutator_name)
        dot = mutator_name.rindex(".")
        dot ? mutator_name[0, dot] : mutator_name
      end

      # Deterministic RFC 4122 UUIDv5-formatted identifier derived from
      # (mutation_id, seq) using 32-bit-safe pure-Ruby SHA-256.
      def deterministic_uuid(mutation_id, seq)
        bytes = sha256_bytes("#{mutation_id}:#{seq}")
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        hex = +""
        i = 0
        while i < 16
          byte = bytes[i]
          hex << HEX_DIGITS[byte >> 4] << HEX_DIGITS[byte & 0x0f]
          hex << "-" if i == 3 || i == 5 || i == 7 || i == 9
          i += 1
        end
        hex
      end

      # --- cruby-only:start ---
      def server_frame
        return nil if InstantRecord.browser?

        ActiveSupport::IsolatedExecutionState[:instant_record_server_mutator_frame]
      end

      def enforcing_server_mutator?
        frame = server_frame
        !frame.nil? && frame.enforcing?
      end

      def server_authorize_create!(record) = server_frame&.authorize_create!(record)
      def server_finalize_create!(record) = server_frame&.finalize_create!(record)
      def server_authorize_update_before!(record) = server_frame&.authorize_update_before!(record)
      def server_finalize_update!(record) = server_frame&.finalize_update!(record)
      def server_authorize_destroy!(record) = server_frame&.authorize_destroy!(record)
      def server_finalize_destroy!(record) = server_frame&.finalize_destroy!(record)
      def server_note_read(record) = server_frame&.note_read(record)

      def with_server_frame(frame)
        previous = ActiveSupport::IsolatedExecutionState[:instant_record_server_mutator_frame]
        ActiveSupport::IsolatedExecutionState[:instant_record_server_mutator_frame] = frame
        yield frame
      ensure
        ActiveSupport::IsolatedExecutionState[:instant_record_server_mutator_frame] = previous
      end

      def execute_on_server(name, normalized, mutation_id)
        with_savepoint do
          if mutation_id && !mutation_id.to_s.empty?
            with_server_frame(ServerFrame.new(mutation_id: mutation_id.to_s, enforcing: false)) do
              dispatch(name, normalized)
            end
          else
            dispatch(name, normalized)
          end
        end
      end

      def registry
        @registry ||= {}
      end

      def reset_registry!
        @registry = {}
      end

      def register(klass, action_name, block = nil)
        return unless klass.name

        registry["#{klass.name}.#{action_name}"] = {
          klass: klass,
          action: action_name.to_s,
          block: block
        }
      end

      def resolve(mutator_name)
        name = mutator_name.to_s
        entry = registry[name]
        return entry if entry

        # Fallback for reloaded classes on CRuby: check allowlisted/loaded Syncable models.
        dot = name.rindex(".")
        return nil unless dot

        owner = name[0, dot]
        action = name[(dot + 1)..]
        model = InstantRecord.synced_model(owner)
        if model && model.respond_to?(:instant_record_sync_actions) && model.instant_record_sync_actions.key?(action)
          return { klass: model, action: action, block: model.instant_record_sync_actions[action] }
        end

        nil
      end

      def dispatch(mutator_name, args)
        entry = resolve(mutator_name)
        raise ArgumentError, "Unknown sync_action: #{mutator_name}" unless entry

        klass = entry[:klass]
        action = entry[:action]
        block = entry[:block]

        if block
          invoke_callable(klass, block, args)
        else
          unless klass.respond_to?(action)
            raise ArgumentError, "sync_action #{mutator_name} has no class method #{klass.name}.#{action}"
          end

          method_obj = klass.method(action)
          invoke_callable(klass, method_obj, args, direct_method: true)
        end
      end

      # Commit guard for ActiveJob: ensures non-DB queue adapters do not enqueue
      # ghost jobs when a server sync_action transaction rolls back.
      module ActiveJobCommitGuard
        private

        def raw_enqueue
          frame = InstantRecord::SyncActions.server_frame
          if frame && InstantRecord::SyncActions.defer_active_job?(self)
            tx = ActiveRecord::Base.connection.current_transaction
            if tx.respond_to?(:after_commit) && ActiveRecord::Base.connection.open_transactions > 0
              deferred_scheduled_at = scheduled_at
              deferred_queue_name = queue_name
              deferred_priority = priority
              tx.after_commit do
                prev_at, prev_queue, prev_priority = scheduled_at, queue_name, priority
                self.scheduled_at = deferred_scheduled_at
                self.queue_name = deferred_queue_name
                self.priority = deferred_priority
                self.successfully_enqueued = false
                super()
              ensure
                self.scheduled_at = prev_at
                self.queue_name = prev_queue
                self.priority = prev_priority
              end
              self.successfully_enqueued = true
              self
            else
              super
            end
          else
            super
          end
        end
      end

      def defer_active_job?(job)
        # If Rails' own EnqueueAfterTransactionCommit is already active for this job,
        # let Rails handle deferral without double-wrapping.
        return false if job.class.respond_to?(:enqueue_after_transaction_commit) && job.class.enqueue_after_transaction_commit

        # DB-transactional queue adapters (e.g., SolidQueue) persist inside the
        # active SQL transaction directly and roll back with it.
        adapter = job.class.queue_adapter
        return false if adapter.class.name.to_s.include?("SolidQueue")

        true
      end

      def install_active_job_guard!
        return unless defined?(ActiveJob::Base)
        return if ActiveJob::Base.ancestors.include?(ActiveJobCommitGuard)

        ActiveJob::Base.prepend(ActiveJobCommitGuard)
      end

      private

      def invoke_callable(klass, callable, args, direct_method: false)
        params = callable.parameters
        if params.empty?
          direct_method ? callable.call : klass.instance_exec(&callable)
        elsif params.all? { |kind, _| kind == :key || kind == :keyreq || kind == :keyrest }
          kwargs = {}
          has_keyrest = params.any? { |kind, _| kind == :keyrest }
          if has_keyrest
            args.each { |k, v| kwargs[k.to_sym] = v }
          else
            params.each do |kind, param_name|
              key = param_name.to_s
              if args.key?(key)
                kwargs[param_name] = args[key]
              elsif kind == :keyreq
                kwargs[param_name] = nil
              end
            end
          end
          direct_method ? callable.call(**kwargs) : klass.instance_exec(**kwargs, &callable)
        else
          direct_method ? callable.call(args) : klass.instance_exec(args, &callable)
        end
      end
      # --- cruby-only:end ---

      def normalize_hash(hash)
        out = {}
        hash.each do |key, val|
          out[key.to_s] = normalize_value(val)
        end
        out
      end

      def normalize_value(value)
        if value.is_a?(Hash)
          normalize_hash(value)
        elsif value.is_a?(Array)
          list = []
          value.each { |item| list << normalize_value(item) }
          list
        elsif value.is_a?(Symbol)
          value.to_s
        elsif value.respond_to?(:usec)
          value.iso8601(InstantRecord::TIME_PRECISION)
        else
          value
        end
      end

      def rotr32(x, n)
        ((x >> n) | ((x << (32 - n)) & MASK32)) & MASK32
      end

      def sha256_bytes(text)
        msg = []
        text.each_byte { |b| msg << b }
        bit_len = msg.length * 8
        msg << 0x80
        msg << 0 while (msg.length % 64) != 56

        # Append 64-bit big-endian bit length (high 32 bits, then low 32 bits).
        hi = (bit_len >> 32) & MASK32
        lo = bit_len & MASK32
        msg << ((hi >> 24) & 0xff) << ((hi >> 16) & 0xff) << ((hi >> 8) & 0xff) << (hi & 0xff)
        msg << ((lo >> 24) & 0xff) << ((lo >> 16) & 0xff) << ((lo >> 8) & 0xff) << (lo & 0xff)

        h0 = SHA256_H[0]
        h1 = SHA256_H[1]
        h2 = SHA256_H[2]
        h3 = SHA256_H[3]
        h4 = SHA256_H[4]
        h5 = SHA256_H[5]
        h6 = SHA256_H[6]
        h7 = SHA256_H[7]

        offset = 0
        while offset < msg.length
          w = Array.new(64, 0)
          i = 0
          while i < 16
            j = offset + i * 4
            w[i] = ((msg[j] << 24) | (msg[j + 1] << 16) | (msg[j + 2] << 8) | msg[j + 3]) & MASK32
            i += 1
          end
          while i < 64
            x = w[i - 15]
            s0 = rotr32(x, 7) ^ rotr32(x, 18) ^ (x >> 3)
            y = w[i - 2]
            s1 = rotr32(y, 17) ^ rotr32(y, 19) ^ (y >> 10)
            w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & MASK32
            i += 1
          end

          a = h0
          b = h1
          c = h2
          d = h3
          e = h4
          f = h5
          g = h6
          h = h7

          i = 0
          while i < 64
            s1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25)
            ch = (e & f) ^ ((e ^ MASK32) & g)
            temp1 = (h + s1 + ch + SHA256_K[i] + w[i]) & MASK32
            s0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22)
            maj = (a & b) ^ (a & c) ^ (b & c)
            temp2 = (s0 + maj) & MASK32

            h = g
            g = f
            f = e
            e = (d + temp1) & MASK32
            d = c
            c = b
            b = a
            a = (temp1 + temp2) & MASK32
            i += 1
          end

          h0 = (h0 + a) & MASK32
          h1 = (h1 + b) & MASK32
          h2 = (h2 + c) & MASK32
          h3 = (h3 + d) & MASK32
          h4 = (h4 + e) & MASK32
          h5 = (h5 + f) & MASK32
          h6 = (h6 + g) & MASK32
          h7 = (h7 + h) & MASK32
          offset += 64
        end

        out = []
        [h0, h1, h2, h3].each do |word|
          out << ((word >> 24) & 0xff)
          out << ((word >> 16) & 0xff)
          out << ((word >> 8) & 0xff)
          out << (word & 0xff)
        end
        out
      end
    end
  end
end
