require "time"

module InstantRecord
  # Copy-on-write local SQLite staging branches.
  #
  # A branch forks the live local SQLite database into an isolated offline copy
  # so a user or AI agent can run bulk edits, inspect the resulting state through
  # the real Rails UI, and then either:
  #
  #   * approve! — extract only the OutboxMutations recorded on the branch and
  #     replay them safely onto current `main` (preserving any remote deltas or
  #     concurrent updates that arrived on `main` during review), then sync.
  #   * discard! — drop the branch file with zero impact on `main` or the server.
  #
  # The extraction, summary, and replay methods are Spinel-safe so the compiled
  # WASM and native runtimes share the exact same merge semantics as CRuby.
  class Branch
    Error = Class.new(StandardError)

    CONFLICT_STRATEGIES = %w[lww branch_wins].freeze

    class << self
      attr_accessor :current, :store_class

      def active?
        !@current.nil? || !env_branch_name.empty?
      end

      def current_name
        return @current.name if @current

        name = env_branch_name
        name.empty? ? nil : name
      end

      # Fork the live local SQLite workspace into an isolated offline branch.
      # With a block, yields the branch handle and safely discards it if the
      # block neither approves nor discards (or raises an exception).
      def open(name: nil, directory: nil, &block)
        raise Error, "Staging branches are only available in the local client runtime" unless InstantRecord.browser?
        raise Error, "Already on staging branch '#{current_name}' — approve or discard it first" if active?
        raise Error, "Local SQLite branching requires CRuby sqlite3 support (or the compiled worker host)" unless store_class

        base_outbox_ids = OutboxMutation.ordered.map(&:id)
        branch_name = normalize_name(name)
        store = store_class.fork!(name: branch_name, directory: directory)

        branch = new(name: branch_name, store: store, base_outbox_ids: base_outbox_ids)
        @current = branch
        Client.forget_database

        return branch unless block

        begin
          result = block.call(branch)
          branch.discard! if branch.active?
          result
        rescue StandardError
          branch.discard! if branch.active?
          raise
        end
      end

      # Extract only OutboxMutations created after `since_ids`, in causal order.
      # Spinel-safe: uses only OutboxMutation.ordered and plain hashes.
      def extract_mutations(since_ids: [])
        excluded = {}
        Array(since_ids).each { |id| excluded[id.to_s] = true }

        extracted = []
        OutboxMutation.ordered.each do |row|
          next if excluded[row.id.to_s]

          mutation = row.as_mutation
          created = row.created_at
          mutation[:created_at] = created.respond_to?(:usec) ? created.utc.iso8601(InstantRecord::TIME_PRECISION) : created.to_s
          extracted << mutation
        end
        extracted
      end

      # Structured diff summary for preview UIs and agents.
      def summary(since_ids: [])
        mutations = extract_mutations(since_ids: since_ids)
        by_operation = {}
        by_type = {}

        mutations.each do |mutation|
          op = mutation[:operation].to_s
          type = mutation[:record_type].to_s
          by_operation[op] = (by_operation[op] || 0) + 1
          by_type[type] = (by_type[type] || 0) + 1
        end

        {
          "count" => mutations.size,
          "by_operation" => by_operation,
          "by_type" => by_type,
          "mutations" => mutations
        }
      end

      # Safely replay extracted branch OutboxMutations onto the currently active
      # `main` SQLite database inside a single transaction.
      #
      # Concurrent remote deltas that arrived on `main` during branch review are
      # preserved:
      #   - Untouched records and newly arrived remote records stay intact.
      #   - Partial `update` payloads merge onto current `main` rows, preserving
      #     concurrent remote changes to other columns.
      #   - Under `conflict: :lww` (default), a branch update whose `updated_at`
      #     is strictly older than `main`'s current row is skipped and reported
      #     in `conflicts` (matching MutationApplier#stale? semantics).
      #   - Under `conflict: :branch_wins`, a stale branch update is restamped
      #     to the approval time so it supersedes the older row on both `main`
      #     and the server.
      #   - Updates to rows deleted on `main` during review, creates whose id
      #     already exists, and redundant destroys are recorded cleanly without
      #     aborting the rest of the replay.
      def replay_mutations(mutations, conflict: :lww)
        strategy = conflict.to_s
        unless CONFLICT_STRATEGIES.include?(strategy)
          raise ArgumentError, "Unknown conflict strategy #{conflict.inspect}; expected :lww or :branch_wins"
        end

        applied = 0
        skipped = 0
        conflicts = []
        list = Array(mutations)
        return { "applied" => 0, "skipped" => 0, "conflicts" => [] } if list.empty?

        OutboxMutation.transaction do
          last_outbox_at = latest_outbox_time

          list.each do |raw|
            mutation = raw.deep_stringify_keys
            mutation_id = mutation["id"].to_s
            record_type = mutation["record_type"].to_s
            record_id = mutation["record_id"].to_s
            operation = mutation["operation"].to_s
            changes = (mutation["changes"] || {}).deep_stringify_keys

            # Idempotency guard: never enqueue the same branch mutation twice.
            if !mutation_id.empty? && OutboxMutation.find_by(id: mutation_id)
              skipped += 1
              next
            end

            model = InstantRecord.synced_model(record_type)
            unless model
              skipped += 1
              conflicts << conflict_entry(mutation_id, record_type, record_id, operation, "unknown record type")
              next
            end

            outcome = Client.applying_remote do
              apply_one_mutation(model, mutation_id, record_type, record_id, operation, changes, strategy)
            end

            if outcome[:status] == :applied
              ts = next_outbox_time(mutation["created_at"], last_outbox_at)
              last_outbox_at = ts
              OutboxMutation.create!(
                id: mutation_id.empty? ? nil : mutation_id,
                record_type: record_type,
                record_id: record_id,
                operation: operation,
                changes_payload: outcome[:changes],
                base_version: outcome[:base_version],
                created_at: ts,
                updated_at: ts
              )
              Client.note_change(record_type, record_id)
              applied += 1
            else
              skipped += 1
              conflicts << conflict_entry(mutation_id, record_type, record_id, operation, outcome[:reason])
            end
          end
        end

        Client.notify_changed if applied > 0
        { "applied" => applied, "skipped" => skipped, "conflicts" => conflicts }
      end

      private

      def env_branch_name
        ENV["INSTANT_RECORD_BRANCH"].to_s
      end

      def normalize_name(name)
        cleaned = name.to_s.strip
        cleaned.empty? ? "staging" : cleaned
      end

      def apply_one_mutation(model, _mutation_id, _record_type, record_id, operation, changes, strategy)
        case operation
        when "create"
          if model.find_by(id: record_id)
            return { status: :skipped, reason: "id already exists" }
          end

          attrs = changes.slice(*model.column_names)
          record = model.new
          record.id = record_id
          record.assign_attributes(attrs.except("id", "server_version", "sync_state"))
          record.server_version = 0
          record.sync_state = "pending"
          record.save!(validate: false)
          { status: :applied, base_version: 0, changes: changes }
        when "update"
          record = model.find_by(id: record_id)
          return { status: :skipped, reason: "record not found" } unless record

          incoming_at = parse_timestamp(changes["updated_at"])
          local_at = record.respond_to?(:updated_at) ? record.updated_at : nil
          effective_changes = changes

          if incoming_at && local_at && incoming_at < local_at
            if strategy == "branch_wins"
              now_utc = Time.now.utc
              # Add 10 usec (Float-safe in Spinel) so iso8601(6) never truncates back to local_at.
              stamped = now_utc > local_at ? now_utc : (local_at.utc + 0.00001)
              effective_changes = changes.merge("updated_at" => stamped.iso8601(InstantRecord::TIME_PRECISION))
            else
              return { status: :skipped, reason: "stale" }
            end
          end

          attrs = effective_changes.except("id", "server_version", "sync_state").slice(*model.column_names)
          record.assign_attributes(attrs)
          record.sync_state = "pending"
          record.save!(validate: false)
          { status: :applied, base_version: record[:server_version] || 0, changes: effective_changes }
        when "destroy"
          record = model.find_by(id: record_id)
          return { status: :skipped, reason: "already destroyed" } unless record

          base_version = record[:server_version] || 0
          record.destroy!
          { status: :applied, base_version: base_version, changes: {} }
        else
          { status: :skipped, reason: "unknown operation" }
        end
      end

      def parse_timestamp(value)
        return nil if value.nil? || value.to_s.empty?

        Client.parse_time(value.to_s)
      rescue ArgumentError
        nil
      end

      def latest_outbox_time
        last = OutboxMutation.ordered.last
        last&.created_at&.utc
      end

      def next_outbox_time(raw_created_at, previous)
        candidate = parse_timestamp(raw_created_at) || Time.now.utc
        if previous && candidate <= previous
          previous + 0.00001
        else
          candidate
        end
      end

      def conflict_entry(mutation_id, record_type, record_id, operation, reason)
        {
          "mutation_id" => mutation_id,
          "record_type" => record_type,
          "record_id" => record_id,
          "operation" => operation,
          "reason" => reason
        }
      end
    end

    attr_reader :name, :base_outbox_ids

    def initialize(name:, store:, base_outbox_ids:)
      @name = name
      @store = store
      @base_outbox_ids = base_outbox_ids.freeze
      @state = :active
    end

    def active?
      @state == :active
    end

    def approved?
      @state == :approved
    end

    def discarded?
      @state == :discarded
    end

    def path
      @store.branch_path
    end

    def staged_mutations
      ensure_active!
      self.class.extract_mutations(since_ids: @base_outbox_ids)
    end

    def staged_count
      staged_mutations.size
    end

    def preview_diff
      ensure_active!
      self.class.summary(since_ids: @base_outbox_ids)
    end

    # Temporarily switch back to `main` while this branch stays open (for
    # inspecting `main` or delivering concurrent remote deltas during review).
    def on_main
      ensure_active!
      previous = self.class.current
      self.class.current = nil
      @store.with_main do
        Client.forget_database
        yield
      end
    ensure
      self.class.current = previous
      Client.forget_database
    end

    # Extract only this branch's queued OutboxMutations, switch back to current
    # `main` (preserving any concurrent updates that arrived during review),
    # replay the mutations onto `main`, and optionally run a sync pass.
    def approve!(sync: false, conflict: :lww)
      ensure_active!
      mutations = self.class.extract_mutations(since_ids: @base_outbox_ids)
      @store.restore_main!
      @state = :approved
      self.class.current = nil
      Client.forget_database

      replay = self.class.replay_mutations(mutations, conflict: conflict)
      @store.cleanup!

      synced = false
      if sync && replay["applied"] > 0
        synced = !!Client.sync_pass
      end

      {
        approved: true,
        name: @name,
        applied: replay["applied"],
        skipped: replay["skipped"],
        conflicts: replay["conflicts"],
        synced: synced
      }
    end

    # Drop the staging SQLite file and return to current `main` with zero
    # mutations applied to `main` and zero server impact.
    def discard!
      ensure_active!
      dropped = self.class.extract_mutations(since_ids: @base_outbox_ids).size
      @store.restore_main!
      @state = :discarded
      self.class.current = nil
      Client.forget_database
      @store.cleanup!

      {
        discarded: true,
        name: @name,
        dropped: dropped
      }
    end

    private

    def ensure_active!
      raise Error, "Staging branch '#{@name}' is already #{@state}" unless active?
    end
  end
end
