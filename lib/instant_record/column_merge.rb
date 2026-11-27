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
      @incoming_node = HLC.node(incoming_hlc)
      @record_hlc = record_hlc
      @winning = {}
      @uncontested = []
    end

    def resolve
      base_attrs, server_touched = inspect_changes_since_base
      own_touched = (touched_since_own_create if @base_version.zero?) || server_touched
      touched = server_touched.values_at(*@columns) + own_touched.values_at(*@columns)
      @notes = Notes.read(@record, touched.compact.flat_map { |entry| entry[:clocks] }.uniq)

      @columns.each do |col|
        merge_column(col, base_attrs[col], server_touched[col], own_touched[col])
      end
      self
    end

    # Nobody else touched any of the columns, and the record's clock is an older
    # one of the sender's.
    def own_run?
      @uncontested == @columns && client_node?(@incoming_node) &&
        HLC.node(@record_hlc) == @incoming_node && HLC.compare(@incoming_hlc, @record_hlc) > 0
    end

    private

    def merge_column(col, base_val, col_info, own_info)
      # Not a conflict when the server did not touch this column since base_version
      # (a disjoint concurrent edit), or when only this client node did and this write
      # is strictly newer: the offline mutations it queued share one base_version.
      if own_info.nil? || same_node_sequential?(col, own_info)
        @winning[col] = @changes[col]
        @uncontested << col
        return
      end

      # What a merge took is dated by the merge, whichever clock it was logged under.
      col_hlc = @notes.dig(col_info[:hlc], "merged") || col_info[:hlc]
      incoming_wins = col_hlc.nil? || HLC.compare(@incoming_hlc, col_hlc) >= 0

      case @model.instant_record_merge_policy(col)
      when :server_wins
        # Server's already-committed value wins on same-column collision.
      when :lww
        @winning[col] = @changes[col] if incoming_wins
      when :union
        merged_val = ColumnUnion.merge(base_val, @record.public_send(col), @changes[col], incoming_wins: incoming_wins)
        @winning[col] = merged_val if merged_val != @record.public_send(col)
      end
    end

    # Inspect Change rows since `base_version` to determine the base snapshot
    # and every column modified on the server since that version, along with
    # the HLC of its last change and those of all of them, for each modified column.
    def inspect_changes_since_base
      record_changes = Change.where(record_type: @record.class.name, record_id: @record.id)
      base_change = record_changes.where(version: @base_version).order(:id).last if @base_version.positive?
      return [{}, every_column_touched] unless base_change

      base_attrs = change_attributes(base_change.attributes_payload)
      changes_since = record_changes
        .where("version > ?", @base_version)
        .where.not(operation: "destroy")
        .order(:version, :id)

      [base_attrs, columns_touched(base_attrs, changes_since)]
    end

    # What was touched since the client itself created the record, whose queued
    # edits have no base version. Nil when the record is not its creation.
    def touched_since_own_create
      return unless client_node?(@incoming_node)

      logged = Change.where(record_type: @record.class.name, record_id: @record.id)
      create = logged.where(operation: "create").order(:id).last
      return unless create && HLC.node(create.hlc) == @incoming_node

      changes = logged.after(create.id).where.not(operation: "destroy")
      columns_touched(change_attributes(create.attributes_payload), changes)
    end

    # Each edit a client queued offline reads every change logged for those before
    # it, so the rows are read as values, without an object for each.
    def columns_touched(base_attrs, changes_since)
      rows = changes_since.pluck(:id, :attributes_payload, :created_at)
      clocks = change_clocks(rows.map(&:first))
      server_touched = {}
      prev_attrs = base_attrs

      rows.each do |id, payload, created_at|
        curr_attrs = change_attributes(payload)
        c_hlc = clocks["#{HLC::CHANGE_PREFIX}#{id}"] || HLC.from_time(curr_attrs["updated_at"] || created_at, node: HLC::SERVER_NODE)
        touch_changed_columns(server_touched, prev_attrs, curr_attrs, hlc: c_hlc)
        prev_attrs = curr_attrs
      end

      # Catch any unlogged direct server column update (e.g. update_columns).
      live_attrs = as_logged(InstantRecord.wire_attributes(@record.attributes))
      touch_changed_columns(server_touched, prev_attrs, live_attrs, hlc: @record_hlc, unlogged: true)

      server_touched
    end

    # Without a base to compare with, any column may have changed, and the
    # record's own clock is the only one known: the same answer for any column.
    def every_column_touched
      # Read for its effect on the save: Rails looks for in-place changes only
      # in columns that have been read.
      @record.attributes

      Hash.new({ hlc: @record_hlc, clocks: [@record_hlc].compact })
    end

    # HLC.change_hlcs by metadata key, which the browser compiles.
    def change_clocks(ids)
      return {} if ids.empty?

      SyncMetadata.where(key: ids.map { |id| "#{HLC::CHANGE_PREFIX}#{id}" }).pluck(:key, :value)
        .to_h.select { |_key, value| HLC.valid?(value) }
    end

    def change_attributes(payload)
      payload.is_a?(Hash) ? payload : {}
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
      @columns.each do |col|
        next if curr_attrs[col] == prev_attrs[col]

        entry = (server_touched[col] ||= { clocks: [] })
        entry[:hlc] = hlc
        entry[:clocks] << hlc if hlc
        entry[:unlogged] = true if unlogged
      end
    end

    # The clocks that touched the column, each as its sender wrote it, are all
    # this client's and the last is older than the incoming one.
    def same_node_sequential?(col, col_info)
      return false if !client_node?(@incoming_node) || col_info[:unlogged] || col_info[:hlc].nil?

      clocks = col_info[:clocks].map { |clock| sender_clock(clock, col) }
      clocks.all? { |clock| HLC.node(clock) == @incoming_node } && HLC.compare(@incoming_hlc, clocks.last) > 0
    end

    # A merge vouches only for the columns it took uncontested. Any other its
    # change shows (a contested one, one changed by hand) is the server's: nil.
    def sender_clock(clock, col)
      note = @notes[clock]
      return clock if note.nil?

      note["from"] if note["columns"].include?(col)
    end

    def client_node?(node)
      !node.nil? && node != HLC::SERVER_NODE && node != HLC::LEGACY_NODE
    end

    # Notes of earlier merges, in SyncMetadata: for one clock a record was logged
    # under by a merge, the clock its sender wrote at, the columns nobody else
    # had touched, and the server clock of the merge.
    module Notes
      PREFIX = "hlc_mrg:".freeze

      class << self
        # The notes there are, by the clock each was logged under.
        def read(record, clocks)
          clocks_by_key = clocks.index_by { |clock| key(record, clock) }
          PayloadBatch.stamps(clocks_by_key.keys).to_h { |key, value| [clocks_by_key[key], JSON.parse(value)] }
        end

        def write(record, hlc, from:, merged:, columns:)
          return if columns.empty?

          SyncMetadata.set(key(record, hlc), JSON.generate("from" => from, "merged" => merged, "columns" => columns))
        end

        # The record's clock as anyone but the client whose run it is may date it.
        def merge_clock(record, record_hlc, incoming_hlc)
          return record_hlc if HLC.node(record_hlc) == HLC.node(incoming_hlc)

          read(record, [record_hlc].compact).dig(record_hlc, "merged") || record_hlc
        end

        private

        def key(record, hlc)
          "#{PREFIX}#{record.class.name}:#{record.id}:#{hlc}"
        end
      end
    end
  end
end
