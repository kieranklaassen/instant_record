require "time"
require "securerandom"

module InstantRecord
  # Server-anchored, string-encoded Hybrid Logical Clock (HLC).
  #
  # Format (fixed-width, lexicographically sortable):
  #   YYYY-MM-DDTHH:MM:SS.UUUUUUZ-CCCC-NNNNNNNN
  #   - pt:   27-char UTC ISO-8601 timestamp with 6 microsecond digits
  #   - lc:   4-char uppercase hex logical counter (0000..FFFF, fits in 16 bits)
  #   - node: 8-char lowercase hex node identifier
  #
  # Why string-encoded instead of 64-bit integer packing:
  # Spinel compiles the browser runtime to wasm32 with 32-bit signed integers
  # and `-DSP_INT_OVERFLOW_MODE_RAISE`. Any 64-bit epoch millisecond/microsecond
  # packing raises `RangeError: integer overflow`. Comparing canonical HLC
  # strings uses pure lexicographical ordering and keeps all integers <= 65_535.
  module HLC
    SERVER_NODE = "00000000".freeze
    LEGACY_NODE = "00000001".freeze
    MAX_COUNTER = 65_535
    COUNTER_WIDTH = 4
    DEFAULT_MAX_DRIFT = 5
    MAX_USEC = 999_999

    FORMAT = /\A(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z)-([0-9A-F]{4})-([0-9a-zA-Z]{1,16})\z/

    KEY_NODE = "hlc_node".freeze
    KEY_LAST = "hlc_last".freeze
    KEY_OFFSET = "hlc_offset".freeze
    ROW_PREFIX = "hlc_row:".freeze
    RECORD_PREFIX = "hlc_rec:".freeze
    CHANGE_PREFIX = "hlc_chg:".freeze
    MUTATION_PREFIX = "hlc_mut:".freeze

    class << self
      # Test seam for injecting a skewed or frozen wall clock without
      # monkeypatching Time.now.
      attr_writer :clock

      def wall_now
        (@clock ? @clock.call : Time.now).utc
      end

      def with_clock(callable)
        previous = @clock
        @clock = callable
        yield
      ensure
        @clock = previous
      end

      def iso_now(time = nil)
        (time || wall_now).utc.iso8601(TIME_PRECISION)
      end

      def valid?(value)
        value.is_a?(String) && FORMAT.match?(value)
      end

      def parse(value)
        return nil unless value.is_a?(String)

        match = FORMAT.match(value)
        return nil unless match

        { pt: match[1], counter: match[2].to_i(16), node: match[3] }
      end

      def encode(pt_str, counter, node)
        "#{pt_str}-#{format('%04X', counter)}-#{node}"
      end

      def compare(a, b)
        a.to_s <=> b.to_s
      end

      def physical_time(hlc)
        parsed = parse(hlc)
        return nil unless parsed

        Time.parse(parsed[:pt]).utc
      rescue ArgumentError
        nil
      end

      def node(hlc)
        parse(hlc)&.fetch(:node)
      end

      def from_time(time, counter: 0, node: LEGACY_NODE)
        return nil if time.nil?

        parsed = time.is_a?(Time) ? time.utc : Time.parse(time.to_s).utc
        encode(parsed.iso8601(TIME_PRECISION), counter, node)
      rescue ArgumentError
        nil
      end

      def max_drift
        configured = InstantRecord.config.max_clock_drift
        configured.nil? ? DEFAULT_MAX_DRIFT : configured.to_f
      end

      # Persistent node identifier for this runtime. Uses SecureRandom.uuid
      # (not SecureRandom.hex) for Spinel compatibility.
      def node_id
        return SERVER_NODE unless InstantRecord.browser?

        existing = metadata_get(KEY_NODE)
        return existing if existing && !existing.empty?

        generated = SecureRandom.uuid.delete("-")[0, 8].downcase
        metadata_set(KEY_NODE, generated)
        generated
      end

      # Server-anchored clock offset in Float seconds (server_utc - local_utc).
      # Only applied on the browser; the server is its own UTC authority.
      def offset
        return 0.0 unless InstantRecord.browser?

        raw = metadata_get(KEY_OFFSET)
        raw ? raw.to_f : 0.0
      end

      def anchored_now(now = nil)
        base = (now || wall_now).utc
        InstantRecord.browser? ? (base + offset).utc : base
      end

      # Anchor this client's physical clock to authoritative server UTC time
      # piggybacked on sync responses. If an earlier unanchored local HLC
      # drifted far into the future relative to the server, re-anchor it so
      # subsequent writes use real server UTC time.
      def observe_server_time(server_time, now: nil)
        return nil if server_time.nil? || server_time.to_s.empty?

        server_utc = server_time.is_a?(Time) ? server_time.utc : Time.parse(server_time.to_s).utc
        local_utc = (now || wall_now).utc
        delta = server_utc - local_utc
        metadata_set(KEY_OFFSET, format("%.6f", delta)) if InstantRecord.browser?

        if InstantRecord.browser? && (last_hlc = last)
          last_pt = physical_time(last_hlc)
          if last_pt && (last_pt - server_utc) > max_drift
            parsed = parse(last_hlc)
            metadata_set(KEY_LAST, encode(server_utc.iso8601(TIME_PRECISION), 0, parsed[:node]))
          end
        end

        delta
      rescue ArgumentError
        nil
      end

      def last
        metadata_get(KEY_LAST)
      end

      # Clamp extreme forward physical-time skew relative to `now`.
      # Legitimate offline writes in the past are never clamped backward; only
      # impossible future timestamps past `now + max_drift` are clamped back
      # to `now` so a skewed client cannot dominate future writes.
      def clamp(hlc, now: nil, max_drift: nil)
        parsed = parse(hlc)
        return nil unless parsed

        reference = (now || wall_now).utc
        limit = max_drift.nil? ? self.max_drift : max_drift.to_f
        pt = Time.parse(parsed[:pt]).utc

        if (pt - reference) > limit
          encode(reference.iso8601(TIME_PRECISION), parsed[:counter], parsed[:node])
        else
          hlc
        end
      rescue ArgumentError
        nil
      end

      # Generate the next strictly monotonic HLC for a local event.
      def tick(now: nil, node: nil)
        current_node = node || node_id
        pt_now = anchored_now(now).iso8601(TIME_PRECISION)
        prev = parse(last)

        next_pt, next_counter =
          if prev.nil? || pt_now > prev[:pt]
            [pt_now, 0]
          else
            increment_counter(prev[:pt], prev[:counter])
          end

        stamped = encode(next_pt, next_counter, current_node)
        metadata_set(KEY_LAST, stamped)
        stamped
      end

      # Incorporate a remote HLC into this node's monotonic clock, clamping
      # extreme forward drift so a skewed remote stamp cannot drag our clock
      # arbitrarily far into the future.
      def receive(remote_hlc, now: nil, node: nil)
        return last unless valid?(remote_hlc)

        reference = anchored_now(now)
        clamped = clamp(remote_hlc, now: reference)
        remote = parse(clamped)
        return last unless remote

        current_node = node || node_id
        pt_now = reference.iso8601(TIME_PRECISION)
        prev = parse(last)

        next_pt, next_counter =
          if prev.nil?
            pt_now > remote[:pt] ? [pt_now, 0] : increment_counter(remote[:pt], remote[:counter])
          elsif pt_now > prev[:pt] && pt_now > remote[:pt]
            [pt_now, 0]
          elsif prev[:pt] == remote[:pt]
            max_c = prev[:counter] >= remote[:counter] ? prev[:counter] : remote[:counter]
            increment_counter(prev[:pt], max_c)
          elsif prev[:pt] > remote[:pt]
            increment_counter(prev[:pt], prev[:counter])
          else
            increment_counter(remote[:pt], remote[:counter])
          end

        stamped = encode(next_pt, next_counter, current_node)
        metadata_set(KEY_LAST, stamped)
        stamped
      end

      # Produce a new HLC strictly greater than all supplied HLCs and the
      # node's own clock. Used by the server when a 3-way merge creates a new
      # state that must supersede both the prior server row and the client's
      # optimistic local copy.
      def advance_past(*hlcs, now: nil, node: SERVER_NODE)
        candidates = hlcs.compact.select { |h| valid?(h) }
        candidates << last if valid?(last)

        reference = anchored_now(now)
        pt_now = reference.iso8601(TIME_PRECISION)
        highest = candidates.max

        next_pt, next_counter =
          if highest.nil?
            [pt_now, 0]
          else
            parsed = parse(highest)
            if pt_now > parsed[:pt]
              [pt_now, 0]
            else
              increment_counter(parsed[:pt], parsed[:counter])
            end
          end

        stamped = encode(next_pt, next_counter, node)
        metadata_set(KEY_LAST, stamped)
        stamped
      end

      # --- SyncMetadata storage helpers -------------------------------------

      def row_hlc(record_type, record_id)
        metadata_get("#{ROW_PREFIX}#{record_type}:#{record_id}")
      end

      def set_row_hlc(record_type, record_id, hlc, force: false)
        return unless valid?(hlc)

        key = "#{ROW_PREFIX}#{record_type}:#{record_id}"
        if !force
          existing = metadata_get(key)
          return existing if valid?(existing) && existing >= hlc
        end
        metadata_set(key, hlc)
        hlc
      end

      def delete_row_hlc(record_type, record_id)
        metadata_delete("#{ROW_PREFIX}#{record_type}:#{record_id}")
      end

      def record_hlc(record_type, record_id)
        metadata_get("#{RECORD_PREFIX}#{record_type}:#{record_id}")
      end

      def set_record_hlc(record_type, record_id, hlc)
        return unless valid?(hlc)

        metadata_set("#{RECORD_PREFIX}#{record_type}:#{record_id}", hlc)
        hlc
      end

      def delete_record_hlc(record_type, record_id)
        metadata_delete("#{RECORD_PREFIX}#{record_type}:#{record_id}")
      end

      def change_hlc(change_id)
        return nil if change_id.nil?

        metadata_get("#{CHANGE_PREFIX}#{change_id}")
      end

      def set_change_hlc(change_id, hlc)
        return unless change_id && valid?(hlc)

        metadata_set("#{CHANGE_PREFIX}#{change_id}", hlc)
        hlc
      end

      def change_hlcs(change_ids)
        ids = Array(change_ids).compact
        return {} if ids.empty? || !defined?(InstantRecord::SyncMetadata)

        keys = ids.map { |id| "#{CHANGE_PREFIX}#{id}" }
        result = {}
        InstantRecord::SyncMetadata.where(key: keys).each do |entry|
          id_str = entry.key.delete_prefix(CHANGE_PREFIX)
          result[id_str.to_i] = entry.value if valid?(entry.value)
        end
        result
      end

      def mutation_hlc(mutation_id)
        return nil if mutation_id.nil?

        metadata_get("#{MUTATION_PREFIX}#{mutation_id}")
      end

      def set_mutation_hlc(mutation_id, hlc)
        return unless mutation_id && valid?(hlc)

        metadata_set("#{MUTATION_PREFIX}#{mutation_id}", hlc)
        hlc
      end

      def delete_mutation_hlc(mutation_id)
        return if mutation_id.nil?

        metadata_delete("#{MUTATION_PREFIX}#{mutation_id}")
      end

      private

      def increment_counter(pt_str, counter)
        if counter >= MAX_COUNTER
          t = Time.parse(pt_str).utc
          bumped =
            if t.usec >= MAX_USEC
              (Time.utc(t.year, t.month, t.day, t.hour, t.min, t.sec) + 1).utc
            else
              Time.utc(t.year, t.month, t.day, t.hour, t.min, t.sec, t.usec + 1)
            end
          [bumped.iso8601(TIME_PRECISION), 0]
        else
          [pt_str, counter + 1]
        end
      end

      def metadata_get(key)
        return nil unless defined?(InstantRecord::SyncMetadata)

        InstantRecord::SyncMetadata.get(key)
      end

      def metadata_set(key, value)
        return unless defined?(InstantRecord::SyncMetadata)

        InstantRecord::SyncMetadata.set(key, value)
      end

      def metadata_delete(key)
        return unless defined?(InstantRecord::SyncMetadata)

        InstantRecord::SyncMetadata.delete(key)
      end
    end
  end
end
