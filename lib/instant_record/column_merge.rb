# frozen_string_literal: true

require "json"
require "instant_record/column_union"
require "instant_record/payload_batch"

module InstantRecord
  # The three-way merge of an update into a record that has changed since the
  # version its sender knew: which of the sent columns win, and with what value.
  # It only reads: the caller writes what won, logs it, and leaves a note (Notes).
  class ColumnMerge
    # Columns that carry bookkeeping/timestamps rather than user-edited fields.
    NON_DATA_COLUMNS = %w[id server_version sync_state created_at updated_at].freeze

    # Fixed byte offset of the node identifier in a canonical HLC string:
    # "YYYY-MM-DDTHH:MM:SS.UUUUUUZ-CCCC-" is 33 ASCII bytes.
    HLC_NODE_OFFSET = 33
    private_constant :HLC_NODE_OFFSET

    # The columns to write with their values, and the names of those among them
    # that nobody else had touched.
    attr_reader :winning, :uncontested

    # `columns` are the names in `changes` to merge. `model` is the class the
    # mutation named, whose `sync_merge` policies hold.
    def initialize(model, record, changes, columns, base_version:, incoming_hlc:, record_hlc:)
      @model = model
      @record = record
      @changes = changes
      @columns = columns
      @base_version = base_version
      @incoming_hlc = incoming_hlc
      @incoming_node = extract_hlc_node(incoming_hlc)
      @incoming_is_client = client_node?(@incoming_node)
      @record_hlc = record_hlc
      @winning = {}
      @uncontested = []
      @prefetched_notes = nil
      @notes = nil
    end

    def resolve
      if @base_version.zero?
        base_attrs = {}
        own_touched = touched_since_own_create
        if own_touched
          server_touched = default_touched_hash
        else
          server_touched = every_column_touched
          own_touched = server_touched
        end
      else
        base_attrs, server_touched = inspect_changes_since_base
        own_touched = server_touched
      end

      @notes = load_notes(server_touched, own_touched)
      policies = @model.instant_record_merge_policies

      i = 0
      len = @columns.size
      while i < len
        col = @columns[i]
        merge_column(col, base_attrs[col], server_touched[col], own_touched[col], policies[col] || :lww)
        i += 1
      end
      self
    end

    # Nobody else touched any of the columns, and the record's clock is an older
    # one of the sender's.
    def own_run?
      @uncontested == @columns && @incoming_is_client &&
        hlc_node_matches?(@record_hlc, @incoming_node) && @incoming_hlc > @record_hlc
    end

    private

    def merge_column(col, base_val, col_info, own_info, policy)
      # Not a conflict when the server did not touch this column since base_version
      # (a disjoint concurrent edit), or when only this client node did and this write
      # is strictly newer: the offline mutations it queued share one base_version.
      if own_info.nil? || same_node_sequential?(col, own_info)
        @winning[col] = @changes[col]
        @uncontested << col
        return
      end

      return if policy == :server_wins

      # What a merge took is dated by the merge, whichever clock it was logged under.
      col_hlc = merged_note_clock(col_info[:hlc]) || col_info[:hlc]
      incoming_wins = col_hlc.nil? || HLC.compare(@incoming_hlc, col_hlc) >= 0

      case policy
      when :lww
        @winning[col] = @changes[col] if incoming_wins
      when :union
        server_val = @record.public_send(col)
        merged_val = ColumnUnion.merge(base_val, server_val, @changes[col], incoming_wins: incoming_wins)
        @winning[col] = merged_val if merged_val != server_val
      end
    end

    # Inspect Change rows since `base_version` to determine the base snapshot
    # and every column modified on the server since that version, along with
    # the HLC of its last change and those of all of them, for each modified column.
    def inspect_changes_since_base
      return [{}, every_column_touched] unless @base_version.positive?

      rows, joined = fetch_changes_since_base(@base_version.to_i)
      len = rows.size
      ver_idx = joined ? 2 : 1
      payload_idx = joined ? 3 : 2
      base_idx = -1
      i = 0
      while i < len
        v = rows[i][ver_idx]
        v = v.to_i unless v.is_a?(Integer)
        break if v != @base_version

        base_idx = i
        i += 1
      end
      return [{}, every_column_touched] if base_idx < 0

      parse_times = ActiveSupport.parse_json_times
      base_attrs = decode_attributes_payload(rows[base_idx][payload_idx], parse_times)
      [base_attrs, columns_touched_from_rows(base_attrs, rows, base_idx + 1, joined: joined, has_version_col: true, parse_times: parse_times)]
    end

    # What was touched since the client itself created the record, whose queued
    # edits have no base version. Nil when the record is not its creation.
    def touched_since_own_create
      return unless @incoming_is_client

      rows, joined = fetch_changes_since_create
      return if rows.empty?

      parse_times = ActiveSupport.parse_json_times
      if joined
        create_hlc = rows[0][4]
        return unless hlc_node_matches?(create_hlc, @incoming_node)

        base_attrs = decode_attributes_payload(rows[0][2], parse_times)
        columns_touched_from_rows(base_attrs, rows, 1, joined: true, has_version_col: false, parse_times: parse_times)
      else
        ids = collect_row_ids(rows, 0)
        raw_clocks = PayloadBatch.change_stamps_for_ids(ids)
        return unless hlc_node_matches?(raw_clocks[ids[0]], @incoming_node)

        base_attrs = decode_attributes_payload(rows[0][1], parse_times)
        columns_touched_from_rows(base_attrs, rows, 1, joined: false, has_version_col: false, preloaded_clocks: raw_clocks, parse_times: parse_times)
      end
    end

    def fetch_changes_since_base(base_version)
      record_type = @record.class.name
      record_id = @record.id
      return [[], false] if record_type.nil? || record_id.nil?

      joined = false
      rows = Change.connection_pool.with_connection do |conn|
        joined = join_metadata?(conn)
        Change.uncached do
          c_table = conn.quote_table_name(Change.table_name)
          q_type = conn.quote(record_type.to_s)
          q_id = conn.quote(record_id.to_s)
          if joined
            m_table = conn.quote_table_name(SyncMetadata.table_name)
            q_mrg_prefix = conn.quote("#{Notes::PREFIX}#{record_type}:#{record_id}:")
            base_sql =
              "SELECT 0, c.\"id\", c.\"version\", c.\"attributes_payload\", c.\"created_at\", mh.\"value\", mn.\"value\" " \
              "FROM #{c_table} c " \
              "LEFT JOIN #{m_table} mh ON mh.\"key\" = '#{HLC::CHANGE_PREFIX}' || c.\"id\" " \
              "LEFT JOIN #{m_table} mn ON mn.\"key\" = #{q_mrg_prefix} || mh.\"value\" " \
              "WHERE c.\"record_type\" = #{q_type} AND c.\"record_id\" = #{q_id} " \
              "AND (c.\"version\" = #{base_version} OR (c.\"version\" > #{base_version} AND c.\"operation\" != 'destroy'))"
            sql =
              if @record_hlc
                q_rec_note = conn.quote("#{Notes::PREFIX}#{record_type}:#{record_id}:#{@record_hlc}")
                "#{base_sql} UNION ALL SELECT 1, 0, 0, NULL, NULL, NULL, \"value\" FROM #{m_table} WHERE \"key\" = #{q_rec_note} ORDER BY 1 ASC, 3 ASC, 2 ASC"
              else
                "#{base_sql} ORDER BY c.\"version\" ASC, c.\"id\" ASC"
              end
            conn.select_rows(sql, "InstantRecord::ColumnMerge Load")
          else
            id_col = conn.quote_column_name("id")
            ver_col = conn.quote_column_name("version")
            payload_col = conn.quote_column_name("attributes_payload")
            created_col = conn.quote_column_name("created_at")
            type_col = conn.quote_column_name("record_type")
            rec_id_col = conn.quote_column_name("record_id")
            op_col = conn.quote_column_name("operation")
            sql = "SELECT #{id_col}, #{ver_col}, #{payload_col}, #{created_col} " \
                  "FROM #{c_table} " \
                  "WHERE #{type_col} = #{q_type} AND #{rec_id_col} = #{q_id} " \
                  "AND (#{ver_col} = #{base_version} OR (#{ver_col} > #{base_version} AND #{op_col} != 'destroy')) " \
                  "ORDER BY #{ver_col} ASC, #{id_col} ASC"
            conn.select_rows(sql, "InstantRecord::ColumnMerge Load")
          end
        end
      end

      extract_record_note!(rows) if joined && @record_hlc
      [rows, joined]
    end

    def fetch_changes_since_create
      record_type = @record.class.name
      record_id = @record.id
      return [[], false] if record_type.nil? || record_id.nil?

      joined = false
      rows = Change.connection_pool.with_connection do |conn|
        joined = join_metadata?(conn)
        Change.uncached do
          c_table = conn.quote_table_name(Change.table_name)
          q_type = conn.quote(record_type.to_s)
          q_id = conn.quote(record_id.to_s)
          if joined
            m_table = conn.quote_table_name(SyncMetadata.table_name)
            q_mrg_prefix = conn.quote("#{Notes::PREFIX}#{record_type}:#{record_id}:")
            base_sql =
              "SELECT 0, c.\"id\", c.\"attributes_payload\", c.\"created_at\", mh.\"value\", mn.\"value\" " \
              "FROM #{c_table} c " \
              "LEFT JOIN #{m_table} mh ON mh.\"key\" = '#{HLC::CHANGE_PREFIX}' || c.\"id\" " \
              "LEFT JOIN #{m_table} mn ON mn.\"key\" = #{q_mrg_prefix} || mh.\"value\" " \
              "WHERE c.\"record_type\" = #{q_type} AND c.\"record_id\" = #{q_id} " \
              "AND c.\"operation\" != 'destroy' " \
              "AND c.\"id\" >= (SELECT MAX(\"id\") FROM #{c_table} " \
              "WHERE \"record_type\" = #{q_type} AND \"record_id\" = #{q_id} AND \"operation\" = 'create')"
            sql =
              if @record_hlc
                q_rec_note = conn.quote("#{Notes::PREFIX}#{record_type}:#{record_id}:#{@record_hlc}")
                "#{base_sql} UNION ALL SELECT 1, 0, NULL, NULL, NULL, \"value\" FROM #{m_table} WHERE \"key\" = #{q_rec_note} ORDER BY 1 ASC, 2 ASC"
              else
                "#{base_sql} ORDER BY c.\"id\" ASC"
              end
            conn.select_rows(sql, "InstantRecord::ColumnMerge Load")
          else
            id_col = conn.quote_column_name("id")
            payload_col = conn.quote_column_name("attributes_payload")
            created_col = conn.quote_column_name("created_at")
            type_col = conn.quote_column_name("record_type")
            rec_id_col = conn.quote_column_name("record_id")
            op_col = conn.quote_column_name("operation")
            sql = "SELECT #{id_col}, #{payload_col}, #{created_col} " \
                  "FROM #{c_table} " \
                  "WHERE #{type_col} = #{q_type} AND #{rec_id_col} = #{q_id} " \
                  "AND #{op_col} != 'destroy' " \
                  "AND #{id_col} >= (SELECT MAX(#{id_col}) FROM #{c_table} " \
                  "WHERE #{type_col} = #{q_type} AND #{rec_id_col} = #{q_id} AND #{op_col} = 'create') " \
                  "ORDER BY #{id_col} ASC"
            conn.select_rows(sql, "InstantRecord::ColumnMerge Load")
          end
        end
      end

      extract_record_note!(rows) if joined && @record_hlc
      [rows, joined]
    end

    def extract_record_note!(rows)
      prefetched = (@prefetched_notes ||= {})
      last_row = rows.last
      if last_row && (last_row[0] == 1 || last_row[0] == "1")
        rows.pop
        prefetched[@record_hlc] = last_row.last
      else
        prefetched[@record_hlc] = nil
      end
    end

    def join_metadata?(conn)
      Change.connection_pool == SyncMetadata.connection_pool &&
        conn.adapter_name.match?(/sqlite|postgres/i)
    end

    # Each edit a client queued offline reads every change logged for those before
    # it, so the rows are read as values, without an object for each.
    def columns_touched_from_rows(base_attrs, rows, start_idx, joined:, has_version_col:, parse_times:, preloaded_clocks: nil)
      server_touched = {}
      prev_attrs = base_attrs
      len = rows.size
      cols = @columns
      col_len = cols.size

      if start_idx < len
        if joined
          payload_idx = has_version_col ? 3 : 2
          created_idx = has_version_col ? 4 : 3
          hlc_idx = has_version_col ? 5 : 4
          note_idx = has_version_col ? 6 : 5
          prefetched = (@prefetched_notes ||= {})
          i = start_idx
          while i < len
            row = rows[i]
            curr_attrs = decode_attributes_payload(row[payload_idx], parse_times)
            c_hlc = nil
            resolved_hlc = false
            j = 0
            while j < col_len
              col = cols[j]
              if curr_attrs[col] != prev_attrs[col]
                unless resolved_hlc
                  raw_hlc = row[hlc_idx]
                  if raw_hlc && HLC.valid?(raw_hlc)
                    c_hlc = raw_hlc
                    prefetched[c_hlc] = row[note_idx]
                  else
                    c_hlc = fallback_change_hlc(curr_attrs, row[created_idx])
                  end
                  resolved_hlc = true
                end
                entry = (server_touched[col] ||= { clocks: [] })
                entry[:hlc] = c_hlc
                entry[:clocks] << c_hlc if c_hlc
              end
              j += 1
            end
            prev_attrs = curr_attrs
            i += 1
          end
        else
          payload_idx = has_version_col ? 2 : 1
          created_idx = has_version_col ? 3 : 2
          clocks = preloaded_clocks || change_clocks(collect_row_ids(rows, start_idx))
          i = start_idx
          while i < len
            row = rows[i]
            curr_attrs = decode_attributes_payload(row[payload_idx], parse_times)
            c_hlc = nil
            resolved_hlc = false
            j = 0
            while j < col_len
              col = cols[j]
              if curr_attrs[col] != prev_attrs[col]
                unless resolved_hlc
                  id = row[0]
                  id = id.to_i unless id.is_a?(Integer)
                  raw_hlc = clocks[id]
                  c_hlc = (raw_hlc && HLC.valid?(raw_hlc)) ? raw_hlc : fallback_change_hlc(curr_attrs, row[created_idx])
                  resolved_hlc = true
                end
                entry = (server_touched[col] ||= { clocks: [] })
                entry[:hlc] = c_hlc
                entry[:clocks] << c_hlc if c_hlc
              end
              j += 1
            end
            prev_attrs = curr_attrs
            i += 1
          end
        end
      end

      # Catch any unlogged direct server column update (e.g. update_columns).
      touch_unlogged_live_columns(server_touched, prev_attrs, parse_times)

      server_touched
    end

    def touch_unlogged_live_columns(server_touched, prev_attrs, parse_times)
      if @record.class.instance_method(:attributes).owner == ActiveRecord::AttributeMethods &&
         @record.class.instance_method(:_read_attribute).owner == ActiveRecord::AttributeMethods::Read
        cols = @columns
        i = 0
        len = cols.size
        while i < len
          col = cols[i]
          live_val =
            if col == "sync_state" || !@record.has_attribute?(col)
              nil
            else
              as_logged_value(@record._read_attribute(col), parse_times)
            end
          if live_val != prev_attrs[col]
            entry = (server_touched[col] ||= { clocks: [] })
            entry[:hlc] = @record_hlc
            entry[:clocks] << @record_hlc if @record_hlc
            entry[:unlogged] = true
          end
          i += 1
        end
      else
        live_attrs = as_logged(InstantRecord.wire_attributes(@record.attributes))
        touch_changed_columns(server_touched, prev_attrs, live_attrs, hlc: @record_hlc, unlogged: true)
      end
    end

    def default_touched_hash
      Hash.new({ hlc: @record_hlc, clocks: @record_hlc ? [@record_hlc] : [] })
    end

    # Without a base to compare with, any column may have changed, and the
    # record's own clock is the only one known: the same answer for any column.
    def every_column_touched
      # Read for its effect on the save: Rails looks for in-place changes only
      # in columns that have been read.
      @record.attributes

      default_touched_hash
    end

    def collect_row_ids(rows, start_idx)
      count = rows.size - start_idx
      return [] if count <= 0

      ids = Array.new(count)
      i = 0
      while i < count
        id = rows[start_idx + i][0]
        ids[i] = id.is_a?(Integer) ? id : id.to_i
        i += 1
      end
      ids
    end

    def change_clocks(ids)
      return {} if ids.empty?

      PayloadBatch.change_stamps_for_ids(ids)
    end

    def fallback_change_hlc(curr_attrs, created_at)
      stamp = curr_attrs["updated_at"]
      stamp = deserialize_created_at(created_at) unless stamp
      HLC.from_time(stamp, node: HLC::SERVER_NODE)
    end

    def deserialize_created_at(raw)
      return raw if raw.nil? || raw.is_a?(Time)

      Change.type_for_attribute("created_at").deserialize(raw)
    end

    def decode_attributes_payload(raw, parse_times)
      return raw if raw.is_a?(Hash)
      return {} unless raw.is_a?(String) && !raw.empty?

      parsed =
        if parse_times
          Change.type_for_attribute("attributes_payload").deserialize(raw)
        else
          JSON.parse(raw, freeze: true)
        end
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    def as_logged_value(value, parse_times)
      if value.respond_to?(:usec)
        value.iso8601(InstantRecord::TIME_PRECISION)
      elsif value.instance_of?(Date)
        parse_times ? value : value.iso8601
      elsif value.is_a?(BigDecimal)
        value.finite? ? value.to_s("F") : value
      else
        value
      end
    end

    # The attributes with dates and decimals as they read back from the log,
    # which is JSON and has neither type. A decimal it has only null for
    # (an infinite one) stays what it is, and so does every other type: those
    # equal what was logged already, or lose part of themselves in JSON.
    def as_logged(attributes)
      typed = attributes.select { |_column, value| value.instance_of?(Date) || value.is_a?(BigDecimal) }
      return attributes if typed.empty?

      attributes.merge(Change.type_for_attribute("attributes_payload").cast(typed).compact)
    end

    def touch_changed_columns(server_touched, prev_attrs, curr_attrs, hlc:, unlogged: false)
      i = 0
      len = @columns.size
      while i < len
        col = @columns[i]
        if curr_attrs[col] != prev_attrs[col]
          entry = (server_touched[col] ||= { clocks: [] })
          entry[:hlc] = hlc
          entry[:clocks] << hlc if hlc
          entry[:unlogged] = true if unlogged
        end
        i += 1
      end
    end

    def load_notes(server_touched, own_touched)
      same = own_touched.equal?(server_touched)
      prefetched = @prefetched_notes
      missing = nil
      notes = nil
      last_entry = nil

      i = 0
      len = @columns.size
      while i < len
        col = @columns[i]
        entry = server_touched[col]
        if entry && !entry.equal?(last_entry)
          last_entry = entry
          clocks = entry[:clocks]
          j = 0
          clen = clocks.size
          while j < clen
            clock = clocks[j]
            if prefetched && prefetched.key?(clock)
              raw = prefetched[clock]
              if raw
                notes ||= {}
                notes[clock] ||= JSON.parse(raw, freeze: true)
              end
            else
              missing ||= []
              missing << clock
            end
            j += 1
          end
        end

        unless same
          own_entry = own_touched[col]
          if own_entry && !own_entry.equal?(entry)
            clocks = own_entry[:clocks]
            j = 0
            clen = clocks.size
            while j < clen
              clock = clocks[j]
              if prefetched && prefetched.key?(clock)
                raw = prefetched[clock]
                if raw
                  notes ||= {}
                  notes[clock] ||= JSON.parse(raw, freeze: true)
                end
              else
                missing ||= []
                missing << clock
              end
              j += 1
            end
          end
        end
        i += 1
      end

      if missing
        missing.uniq! if missing.size > 1
        fetched = Notes.read(@record, missing)
        if !fetched.empty?
          notes ? notes.merge!(fetched) : (notes = fetched)
        end
      end

      notes || {}
    end

    def merged_note_clock(clock)
      note = @notes[clock]
      note && note["merged"]
    end

    # The clocks that touched the column, each as its sender wrote it, are all
    # this client's and the last is older than the incoming one.
    def same_node_sequential?(col, col_info)
      return false if !@incoming_is_client || col_info[:unlogged] || col_info[:hlc].nil?

      clocks = col_info[:clocks]
      len = clocks.size
      last_sender = nil
      i = 0
      while i < len
        sender = sender_clock(clocks[i], col)
        return false unless hlc_node_matches?(sender, @incoming_node)

        last_sender = sender
        i += 1
      end
      !last_sender.nil? && @incoming_hlc > last_sender
    end

    # A merge vouches only for the columns it took uncontested. Any other its
    # change shows (a contested one, one changed by hand) is the server's: nil.
    def sender_clock(clock, col)
      note = @notes[clock]
      return clock if note.nil?

      note["from"] if note["columns"].include?(col)
    end

    def extract_hlc_node(hlc)
      return nil unless hlc.is_a?(String) && HLC::FORMAT.match?(hlc)

      hlc.byteslice(HLC_NODE_OFFSET, hlc.bytesize - HLC_NODE_OFFSET)
    end

    def hlc_node_matches?(hlc, node)
      return false unless node && hlc.is_a?(String) &&
                          hlc.bytesize == HLC_NODE_OFFSET + node.bytesize &&
                          hlc.end_with?(node) &&
                          HLC::FORMAT.match?(hlc)

      true
    end

    def client_node?(node)
      !node.nil? && node != HLC::SERVER_NODE && node != HLC::LEGACY_NODE
    end

    # Notes of earlier merges, in SyncMetadata: for one clock a record was logged
    # under by a merge, the clock its sender wrote at, the columns nobody else
    # had touched, and the server clock of the merge.
    module Notes
      PREFIX = "hlc_mrg:"

      class << self
        # The notes there are, by the clock each was logged under.
        def read(record, clocks)
          return {} if clocks.empty?

          prefix = "#{PREFIX}#{record.class.name}:#{record.id}:"
          if clocks.size == 1
            clock = clocks[0]
            k = "#{prefix}#{clock}"
            raw = PayloadBatch.stamps([k])[k]
            return raw ? { clock => JSON.parse(raw) } : {}
          end

          len = clocks.size
          keys = Array.new(len)
          clocks_by_key = {}
          i = 0
          while i < len
            clock = clocks[i]
            k = "#{prefix}#{clock}"
            keys[i] = k
            clocks_by_key[k] = clock
            i += 1
          end

          stamps = PayloadBatch.stamps(keys)
          return {} if stamps.empty?

          result = {}
          stamps.each do |k, value|
            result[clocks_by_key[k]] = JSON.parse(value)
          end
          result
        end

        def write(record, hlc, from:, merged:, columns:)
          return if columns.empty?

          SyncMetadata.set(key(record, hlc), JSON.generate("from" => from, "merged" => merged, "columns" => columns))
        end

        # The record's clock as anyone but the client whose run it is may date it.
        def merge_clock(record, record_hlc, incoming_hlc)
          return record_hlc if HLC.node(record_hlc) == HLC.node(incoming_hlc)
          return record_hlc if record_hlc.nil?

          read(record, [record_hlc]).dig(record_hlc, "merged") || record_hlc
        end

        private

        def key(record, hlc)
          "#{PREFIX}#{record.class.name}:#{record.id}:#{hlc}"
        end
      end
    end
  end
end
