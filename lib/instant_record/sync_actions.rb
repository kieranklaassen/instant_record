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

    # Pure-Ruby 16-bit-split SHA-256 constants (FIPS 180-4) for deterministic
    # UUID derivation across CRuby and 32-bit signed Spinel (`-DSP_INT_OVERFLOW_MODE_RAISE`)
    # without Digest or >31-bit integer overflow.
    SHA256_K_HI = [
      0x428a, 0x7137, 0xb5c0, 0xe9b5, 0x3956, 0x59f1, 0x923f, 0xab1c,
      0xd807, 0x1283, 0x2431, 0x550c, 0x72be, 0x80de, 0x9bdc, 0xc19b,
      0xe49b, 0xefbe, 0x0fc1, 0x240c, 0x2de9, 0x4a74, 0x5cb0, 0x76f9,
      0x983e, 0xa831, 0xb003, 0xbf59, 0xc6e0, 0xd5a7, 0x06ca, 0x1429,
      0x27b7, 0x2e1b, 0x4d2c, 0x5338, 0x650a, 0x766a, 0x81c2, 0x9272,
      0xa2bf, 0xa81a, 0xc24b, 0xc76c, 0xd192, 0xd699, 0xf40e, 0x106a,
      0x19a4, 0x1e37, 0x2748, 0x34b0, 0x391c, 0x4ed8, 0x5b9c, 0x682e,
      0x748f, 0x78a5, 0x84c8, 0x8cc7, 0x90be, 0xa450, 0xbef9, 0xc671
    ].freeze

    SHA256_K_LO = [
      0x2f98, 0x4491, 0xfbcf, 0xdba5, 0xc25b, 0x11f1, 0x82a4, 0x5ed5,
      0xaa98, 0x5b01, 0x85be, 0x7dc3, 0x5d74, 0xb1fe, 0x06a7, 0xf174,
      0x69c1, 0x4786, 0x9dc6, 0xa1cc, 0x2c6f, 0x84aa, 0xa9dc, 0x88da,
      0x5152, 0xc66d, 0x27c8, 0x7fc7, 0x0bf3, 0x9147, 0x6351, 0x2967,
      0x0a85, 0x2138, 0x6dfc, 0x0d13, 0x7354, 0x0abb, 0xc92e, 0x2c85,
      0xe8a1, 0x664b, 0x8b70, 0x51a3, 0xe819, 0x0624, 0x3585, 0xa070,
      0xc116, 0x6c08, 0x774c, 0xbcb5, 0x0cb3, 0xaa4a, 0xca4f, 0x6ff3,
      0x82ee, 0x636f, 0x7814, 0x0208, 0xfffa, 0x6ceb, 0xa3f7, 0x78f2
    ].freeze

    SHA256_H_HI = [0x6a09, 0xbb67, 0x3c6e, 0xa54f, 0x510e, 0x9b05, 0x1f83, 0x5be0].freeze
    SHA256_H_LO = [0xe667, 0xae85, 0xf372, 0xf53a, 0x527f, 0x688c, 0xd9ab, 0xcd19].freeze

    HEX_DIGITS = "0123456789abcdef".freeze
    MASK16 = 0xffff

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

      # Delegated to InstantRecord::Host so compiled builds use native SQLite SAVEPOINT.
      def with_savepoint(&block)
        InstantRecord::Host.with_savepoint(&block)
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

      def rotr32_hi(hi, lo, n)
        if n < 16
          (hi >> n) | ((lo & ((1 << n) - 1)) << (16 - n))
        else
          m = n - 16
          (lo >> m) | ((hi & ((1 << m) - 1)) << (16 - m))
        end
      end

      def rotr32_lo(hi, lo, n)
        if n < 16
          (lo >> n) | ((hi & ((1 << n) - 1)) << (16 - n))
        else
          m = n - 16
          (hi >> m) | ((lo & ((1 << m) - 1)) << (16 - m))
        end
      end

      def sha256_bytes(text)
        msg = []
        text.each_byte { |b| msg << b }
        byte_len = msg.length
        msg << 0x80
        msg << 0 while (msg.length % 64) != 56

        # Append 64-bit big-endian bit length using 16-bit words (safe on 32-bit signed ints).
        len_lo = (byte_len & 0x1fff) << 3
        len_mid = (byte_len >> 13) & MASK16
        len_hi = (byte_len >> 29) & MASK16
        msg << 0 << 0 << ((len_hi >> 8) & 0xff) << (len_hi & 0xff)
        msg << ((len_mid >> 8) & 0xff) << (len_mid & 0xff) << ((len_lo >> 8) & 0xff) << (len_lo & 0xff)

        h0_h = SHA256_H_HI[0]; h0_l = SHA256_H_LO[0]
        h1_h = SHA256_H_HI[1]; h1_l = SHA256_H_LO[1]
        h2_h = SHA256_H_HI[2]; h2_l = SHA256_H_LO[2]
        h3_h = SHA256_H_HI[3]; h3_l = SHA256_H_LO[3]
        h4_h = SHA256_H_HI[4]; h4_l = SHA256_H_LO[4]
        h5_h = SHA256_H_HI[5]; h5_l = SHA256_H_LO[5]
        h6_h = SHA256_H_HI[6]; h6_l = SHA256_H_LO[6]
        h7_h = SHA256_H_HI[7]; h7_l = SHA256_H_LO[7]

        offset = 0
        while offset < msg.length
          w_h = Array.new(64, 0)
          w_l = Array.new(64, 0)
          i = 0
          while i < 16
            j = offset + i * 4
            w_h[i] = (msg[j] << 8) | msg[j + 1]
            w_l[i] = (msg[j + 2] << 8) | msg[j + 3]
            i += 1
          end
          while i < 64
            xh = w_h[i - 15]; xl = w_l[i - 15]
            s0_h = rotr32_hi(xh, xl, 7) ^ rotr32_hi(xh, xl, 18) ^ (xh >> 3)
            s0_l = rotr32_lo(xh, xl, 7) ^ rotr32_lo(xh, xl, 18) ^ ((xl >> 3) | ((xh & 7) << 13))

            yh = w_h[i - 2]; yl = w_l[i - 2]
            s1_h = rotr32_hi(yh, yl, 17) ^ rotr32_hi(yh, yl, 19) ^ (yh >> 10)
            s1_l = rotr32_lo(yh, yl, 17) ^ rotr32_lo(yh, yl, 19) ^ ((yl >> 10) | ((yh & 0x3ff) << 6))

            sum_l = w_l[i - 16] + s0_l + w_l[i - 7] + s1_l
            w_l[i] = sum_l & MASK16
            w_h[i] = (w_h[i - 16] + s0_h + w_h[i - 7] + s1_h + (sum_l >> 16)) & MASK16
            i += 1
          end

          ah = h0_h; al = h0_l
          bh = h1_h; bl = h1_l
          ch = h2_h; cl = h2_l
          dh = h3_h; dl = h3_l
          eh = h4_h; el = h4_l
          fh = h5_h; fl = h5_l
          gh = h6_h; gl = h6_l
          hh = h7_h; hl = h7_l

          i = 0
          while i < 64
            s1_h = rotr32_hi(eh, el, 6) ^ rotr32_hi(eh, el, 11) ^ rotr32_hi(eh, el, 25)
            s1_l = rotr32_lo(eh, el, 6) ^ rotr32_lo(eh, el, 11) ^ rotr32_lo(eh, el, 25)
            ch_h = (eh & fh) ^ ((eh ^ MASK16) & gh)
            ch_l = (el & fl) ^ ((el ^ MASK16) & gl)

            t1_l = hl + s1_l + ch_l + SHA256_K_LO[i] + w_l[i]
            t1_h = (hh + s1_h + ch_h + SHA256_K_HI[i] + w_h[i] + (t1_l >> 16)) & MASK16
            t1_l &= MASK16

            s0_h = rotr32_hi(ah, al, 2) ^ rotr32_hi(ah, al, 13) ^ rotr32_hi(ah, al, 22)
            s0_l = rotr32_lo(ah, al, 2) ^ rotr32_lo(ah, al, 13) ^ rotr32_lo(ah, al, 22)
            maj_h = (ah & bh) ^ (ah & ch) ^ (bh & ch)
            maj_l = (al & bl) ^ (al & cl) ^ (bl & cl)

            t2_l = s0_l + maj_l
            t2_h = (s0_h + maj_h + (t2_l >> 16)) & MASK16
            t2_l &= MASK16

            hh = gh; hl = gl
            gh = fh; gl = fl
            fh = eh; fl = el
            el = dl + t1_l
            eh = (dh + t1_h + (el >> 16)) & MASK16
            el &= MASK16
            dh = ch; dl = cl
            ch = bh; cl = bl
            bh = ah; bl = al
            al = t1_l + t2_l
            ah = (t1_h + t2_h + (al >> 16)) & MASK16
            al &= MASK16
            i += 1
          end

          h0_l += al; h0_h = (h0_h + ah + (h0_l >> 16)) & MASK16; h0_l &= MASK16
          h1_l += bl; h1_h = (h1_h + bh + (h1_l >> 16)) & MASK16; h1_l &= MASK16
          h2_l += cl; h2_h = (h2_h + ch + (h2_l >> 16)) & MASK16; h2_l &= MASK16
          h3_l += dl; h3_h = (h3_h + dh + (h3_l >> 16)) & MASK16; h3_l &= MASK16
          h4_l += el; h4_h = (h4_h + eh + (h4_l >> 16)) & MASK16; h4_l &= MASK16
          h5_l += fl; h5_h = (h5_h + fh + (h5_l >> 16)) & MASK16; h5_l &= MASK16
          h6_l += gl; h6_h = (h6_h + gh + (h6_l >> 16)) & MASK16; h6_l &= MASK16
          h7_l += hl; h7_h = (h7_h + hh + (h7_l >> 16)) & MASK16; h7_l &= MASK16
          offset += 64
        end

        [
          (h0_h >> 8) & 0xff, h0_h & 0xff, (h0_l >> 8) & 0xff, h0_l & 0xff,
          (h1_h >> 8) & 0xff, h1_h & 0xff, (h1_l >> 8) & 0xff, h1_l & 0xff,
          (h2_h >> 8) & 0xff, h2_h & 0xff, (h2_l >> 8) & 0xff, h2_l & 0xff,
          (h3_h >> 8) & 0xff, h3_h & 0xff, (h3_l >> 8) & 0xff, h3_l & 0xff
        ]
      end
    end
  end
end
