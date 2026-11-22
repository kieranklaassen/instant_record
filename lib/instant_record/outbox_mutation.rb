module InstantRecord
  # Browser-local durable outbox. One row per write, created in the same
  # transaction as the record change. Drained in insertion order on sync.
  class OutboxMutation < ActiveRecord::Base
    self.table_name = "instant_record_outbox"

    serialize :changes_payload, coder: JSON
    serialize :rollback_payload, coder: JSON

    before_create { self.id ||= self.class.next_monotonic_id }

    scope :ordered, -> { order(:created_at, :id) }

    # Class methods rather than parameterized scopes so Roundhouse/Spinel AOT
    # compilation handles them identically to CRuby ActiveRecord.
    def self.matured(now = Time.now.utc)
      where("release_at IS NULL OR release_at <= :now", now: now)
    end

    def self.held(now = Time.now.utc)
      where("release_at IS NOT NULL AND release_at > :now", now: now)
    end

    # Lexicographically monotonic IDs using string timestamps + a per-process
    # sequence counter (no 64-bit integer math for wasm32 Spinel), so multiple
    # writes within the same millisecond preserve exact insertion order.
    def self.next_monotonic_id
      stamp = Time.now.utc.strftime("%Y%m%d%H%M%S%6N")
      if @last_id_stamp == stamp
        @last_id_seq = (@last_id_seq || 0) + 1
      else
        @last_id_stamp = stamp
        @last_id_seq = 0
      end
      "#{stamp}-#{format('%04x', @last_id_seq)}-#{SecureRandom.hex(6)}"
    end

    def held?(now = Time.now.utc)
      !release_at.nil? && release_at > now
    end

    def matured?(now = Time.now.utc)
      release_at.nil? || release_at <= now
    end

    def as_mutation
      {
        id: id,
        record_type: record_type,
        record_id: record_id,
        operation: operation,
        changes: changes_payload,
        base_version: base_version
      }
    end
  end
end
