require "securerandom"

module InstantRecord
  # Local non-destructive quarantine ledger for offline writes the server
  # rejected or last-write-wins overwrote. A notice keeps the user's attempted
  # changes alongside the winning server attributes and human-readable reason so
  # the write can be retried, forked into a new record, or dismissed explicitly.
  class SyncNotice < ActiveRecord::Base
    self.table_name = "instant_record_sync_notices"

    KINDS = %w[rejected conflict].freeze
    NON_WRITABLE_COLUMNS = %w[id server_version sync_state created_at updated_at].freeze

    serialize :attempted_changes, coder: JSON
    serialize :server_attributes, coder: JSON

    before_create { self.id = SecureRandom.uuid if id.blank? }

    scope :active, -> { where(dismissed_at: nil) }
    scope :recent, -> { order(created_at: :desc, id: :desc) }
    scope :for_record, ->(type, record_id) { where(record_type: type.to_s, record_id: record_id.to_s) }

    # Record a notice once per mutation_id (when present), preserving attempted
    # local changes and winning server attributes as plain string-keyed hashes.
    def self.record!(kind:, record_type:, record_id:, operation:, reason:, attempted_changes: {}, server_attributes: {}, server_version: 0, mutation_id: nil)
      mid = mutation_id.to_s
      if mid.length > 0
        existing = find_by(mutation_id: mid)
        return existing if existing
      end

      create!(
        mutation_id: mid.length > 0 ? mid : nil,
        kind: kind.to_s,
        record_type: record_type.to_s,
        record_id: record_id.to_s,
        operation: operation.to_s,
        reason: reason.to_s,
        attempted_changes: normalize_hash(attempted_changes),
        server_attributes: normalize_hash(server_attributes),
        server_version: server_version.to_i
      )
    end

    # Dispatch one user resolution ("retry", "fork", "dismiss") by id and return
    # a JSON-ready status hash for bridge and HTTP callers.
    def self.resolve(id, action:, overrides: {})
      notice = find_by(id: id.to_s)
      raise ArgumentError, "Sync notice not found: #{id}" unless notice

      clean_overrides = normalize_hash(overrides)
      record =
        case action.to_s
        when "dismiss"
          notice.dismiss!
          nil
        when "retry"
          notice.retry!(clean_overrides)
        when "fork"
          notice.fork!(clean_overrides)
        else
          raise ArgumentError, "Unknown sync notice action: #{action}"
        end

      {
        "ok" => true,
        "action" => action.to_s,
        "notice" => notice.as_notice,
        "record_id" => record ? record.id.to_s : nil,
        "notices" => active.recent.map(&:as_notice)
      }
    end

    def self.normalize_hash(value)
      return {} unless value.is_a?(Hash)

      out = {}
      value.each { |k, v| out[k.to_s] = v }
      out
    end

    def active?
      dismissed_at.nil?
    end

    def conflict?
      kind == "conflict"
    end

    def rejected?
      kind == "rejected"
    end

    def dismiss!
      update!(dismissed_at: Time.now.utc)
      self
    end

    # Re-apply the quarantined local write so Syncable enqueues a fresh outbox
    # mutation with a new timestamp and mutation_id, then mark this notice done.
    def retry!(overrides = {})
      model = synced_model!
      record = nil

      self.class.transaction do
        case operation
        when "create"
          attrs = writable_attributes(model, attempted_changes, overrides)
          record = model.find_by(id: record_id)
          if record
            record.update!(attrs)
          else
            record = model.create!(attrs.merge("id" => record_id))
          end
        when "update"
          record = model.find_by(id: record_id)
          if record
            attrs = writable_attributes(model, attempted_changes, overrides)
            record.assign_attributes(attrs)
            bump_updated_at!(record)
            record.save!
          else
            attrs = writable_attributes(model, server_attributes, attempted_changes, overrides)
            record = model.create!(attrs.merge("id" => record_id))
          end
        when "destroy"
          record = model.find_by(id: record_id)
          record.destroy! if record
        else
          raise ArgumentError, "Unknown operation: #{operation}"
        end

        dismiss!
      end

      record
    end

    # Create a brand-new record (fresh UUID) carrying the user's attempted local
    # changes on top of the server/current base attributes, leaving the winning
    # server record untouched.
    def fork!(overrides = {})
      model = synced_model!
      base = server_attributes.is_a?(Hash) && !server_attributes.empty? ? server_attributes : current_record_attributes(model)
      attrs = writable_attributes(model, base, attempted_changes, overrides)
      record = nil

      self.class.transaction do
        record = model.create!(attrs)
        dismiss!
      end

      record
    end

    # Field-level comparison between attempted local values and winning server
    # attributes, excluding gem bookkeeping columns.
    def field_diffs
      attempted = self.class.normalize_hash(attempted_changes)
      server = self.class.normalize_hash(server_attributes)
      keys =
        if operation == "destroy"
          server.keys - NON_WRITABLE_COLUMNS
        else
          attempted.keys - NON_WRITABLE_COLUMNS
        end

      diffs = []
      keys.each do |field|
        local_val = operation == "destroy" ? nil : attempted[field]
        server_val = server[field]
        next if local_val == server_val && !server.empty?

        diffs << { "field" => field, "local" => local_val, "server" => server_val }
      end
      diffs
    end

    def as_notice
      {
        "id" => id.to_s,
        "mutation_id" => mutation_id.to_s,
        "kind" => kind.to_s,
        "record_type" => record_type.to_s,
        "record_id" => record_id.to_s,
        "operation" => operation.to_s,
        "reason" => reason.to_s,
        "attempted_changes" => self.class.normalize_hash(attempted_changes),
        "server_attributes" => self.class.normalize_hash(server_attributes),
        "server_version" => server_version.to_i,
        "dismissed_at" => dismissed_at ? dismissed_at.utc.iso8601(TIME_PRECISION) : nil,
        "created_at" => created_at ? created_at.utc.iso8601(TIME_PRECISION) : nil
      }
    end

    private

    def synced_model!
      model = InstantRecord.synced_model(record_type)
      raise ArgumentError, "Unknown synced model: #{record_type}" unless model

      model
    end

    def current_record_attributes(model)
      existing = model.find_by(id: record_id)
      existing ? InstantRecord.wire_attributes(existing.attributes) : {}
    end

    # Ensure a retried update always carries a timestamp strictly newer than
    # the winning server row (even under clock skew) so LWW accepts the retry.
    def bump_updated_at!(record)
      return unless record.respond_to?(:updated_at=)

      now = Time.now.utc
      floor = record.updated_at ? record.updated_at.utc + 0.000001 : now
      record.updated_at = now > floor ? now : floor
    end

    def writable_attributes(model, *hashes)
      allowed = model.column_names - NON_WRITABLE_COLUMNS
      merged = {}
      hashes.each do |hash|
        next unless hash.is_a?(Hash)

        hash.each do |key, value|
          name = key.to_s
          merged[name] = value if allowed.include?(name)
        end
      end
      merged
    end
  end
end
