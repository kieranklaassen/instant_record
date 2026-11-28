# frozen_string_literal: true

module InstantRecord
  class << self
    # record_payload for many records, with their clocks read together. The
    # same hashes, key for key. Server only, so it is kept out of
    # instant_record.rb, which the browser build compiles.
    # Plain unloaded relations are read directly from Active Record's result
    # without loading the relation, and returned attribute strings may be frozen.
    def record_payloads(records)
      if PayloadBatch.direct_relation?(records)
        result = records.send(:exec_main_query)
        return [] if result.empty?

        if (payloads = PayloadBatch.direct_payloads(records, result))
          return payloads
        end

        rows = records.send(:instantiate_records, result)
        return PayloadBatch.record_payloads_from_rows(rows, PayloadBatch::RowReader.new)
      end

      # Asked first: to_a loads the relation.
      reader = PayloadBatch::RowReader.new if PayloadBatch.alike?(records)
      rows = records.to_a
      return [] if rows.empty?

      PayloadBatch.record_payloads_from_rows(rows, reader)
    end
  end

  # The clocks of a batch of rows, read a slice at a time rather than one by one.
  module PayloadBatch
    # Keys per query, under every supported database's bind limit.
    SLICE = 500

    SYNC_STATE = "sync_state"
    SERVER_VERSION = "server_version"
    UTC_DATETIME_RE = /\A\d{4}-(?:(?:0[13578]|1[02])-(?:0[1-9]|[12]\d|3[01])|(?:0[469]|11)-(?:0[1-9]|[12]\d|30)|02-(?:0[1-9]|1\d|2[0-8])) (?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d\.\d{6}\z/

    KIND_STRING = 0
    KIND_STRING_DUP = 1
    KIND_INTEGER = 2
    KIND_UTC_DATETIME = 3
    KIND_GENERIC = 4
    SYNCABLE_FILE = InstantRecord::Syncable.instance_method(:assign_instant_record_uuid).source_location&.first
    private_constant :SYNCABLE_FILE, :SYNC_STATE, :SERVER_VERSION, :UTC_DATETIME_RE,
                     :KIND_STRING, :KIND_STRING_DUP, :KIND_INTEGER, :KIND_UTC_DATETIME, :KIND_GENERIC

    # `record.attributes` for rows of one query. That call makes an object per
    # column to learn which columns a row has. Rows of one query and class have
    # the same, so it is asked of the first and the rest are read by name.
    class RowReader
      def initialize
        @names = {}.compare_by_identity
        @wire_names = {}.compare_by_identity
      end

      def attributes(record)
        model = record.class
        unless @names.key?(model)
          given = record.attributes
          @names[model] = plain?(model) ? given.keys : nil
          return given
        end
        return record.attributes unless (names = @names[model])

        found = {}
        names.each { |name| found[name] = record._read_attribute(name) }
        found
      end

      # Build wire attributes directly (omitting sync_state and formatting
      # timestamps at TIME_PRECISION) in one hash allocation per row.
      def wire_attributes(record)
        model = record.class
        unless @wire_names.key?(model)
          given = record.attributes
          if plain?(model)
            kept = given.keys
            kept.delete("sync_state")
            kept.map! { |name| -name }
            @wire_names[model] = kept
            @names[model] = given.keys unless @names.key?(model)
          else
            @wire_names[model] = nil
            @names[model] = nil unless @names.key?(model)
          end
          return PayloadBatch.wire_hash(given)
        end
        return PayloadBatch.wire_hash(record.attributes) unless (names = @wire_names[model])

        found = {}
        i = 0
        len = names.size
        while i < len
          name = names[i]
          value = record._read_attribute(name)
          value = value.iso8601(InstantRecord::TIME_PRECISION) if value.respond_to?(:usec)
          found[name] = value
          i += 1
        end
        found
      end

      private

      # A model that answers for its attributes itself is asked, row by row. So
      # is one whose callbacks see each row as it loads: they can leave a row
      # with other columns, or the same in another order. Syncable's own
      # after_find does neither. A model that overrides how Active Record makes
      # its rows is not looked for.
      def plain?(model)
        PayloadBatch.plain_model?(model)
      end
    end

    class << self
      # Whether `rows` are the rows of one query, untouched. A loaded relation,
      # one with methods of its own and an association's collection can hold
      # rows that came another way.
      def alike?(rows)
        rows.is_a?(ActiveRecord::Relation) && !rows.is_a?(ActiveRecord::Associations::CollectionProxy) &&
          !rows.loaded? && !rows.eager_loading? &&
          rows.singleton_methods.empty? && rows.singleton_class.ancestors.second == rows.class
      end

      # Stamps by metadata key, as stored: the single reads send a stamp
      # whatever its form, so these do not filter (HLC.change_hlcs does).
      # Checked out and uncached like Change.poll, for the same reasons: a
      # streaming loop reads these once per poll.
      def stamps(keys)
        found = {}
        return found if keys.empty?

        unique_keys = keys.uniq
        SyncMetadata.connection_pool.with_connection do |conn|
          SyncMetadata.uncached do
            table = conn.quote_table_name(SyncMetadata.table_name)
            k_col = conn.quote_column_name("key")
            v_col = conn.quote_column_name("value")
            base_prefix = "SELECT #{k_col}, #{v_col} FROM #{table} WHERE #{k_col}"
            plain_in_prefix = "#{base_prefix} IN ('"

            i = 0
            total = unique_keys.size
            while i < total
              limit = i + SLICE
              limit = total if limit > total
              slice_len = limit - i
              rows =
                if slice_len == 1
                  k = unique_keys[i]
                  if plain_sql_string?(k)
                    conn.select_rows("#{base_prefix} = '#{k}'", "InstantRecord::SyncMetadata Pluck")
                  else
                    SyncMetadata.where(key: [k]).pluck(:key, :value)
                  end
                else
                  slice = (i == 0 && limit == total) ? unique_keys : unique_keys[i, slice_len]
                  if plain_sql_strings?(slice)
                    conn.select_rows("#{plain_in_prefix}#{slice.join("','")}')", "InstantRecord::SyncMetadata Pluck")
                  else
                    SyncMetadata.where(key: slice).pluck(:key, :value)
                  end
                end

              r = 0
              rlen = rows.size
              while r < rlen
                pair = rows[r]
                found[pair[0]] = pair[1]
                r += 1
              end
              i = limit
            end
          end
        end
        found
      end

      # Change#as_event with the change's clock already read. Change is compiled
      # for the browser, so its own method is left as it is.
      def event(change, stamp)
        event = {
          type: change.record_type,
          id: change.record_id,
          operation: change.operation,
          version: change.version,
          attributes: change.attributes_payload
        }
        event[:hlc] = stamp if stamp
        event
      end

      # The stamps of many changes, by change id. A change that has none is left out.
      def change_stamps(changes)
        rows = changes.is_a?(Array) ? changes : changes.to_a
        len = rows.size
        return {} if len == 0

        ids = Array.new(len)
        i = 0
        while i < len
          ids[i] = rows[i].id
          i += 1
        end
        change_stamps_for_ids(ids)
      end

      def change_stamps_for_ids(ids)
        len = ids.size
        return {} if len == 0

        all_int_ids = true
        i = 0
        while i < len
          id = ids[i]
          unless id.is_a?(Integer) && id >= 0
            all_int_ids = false
            break
          end
          i += 1
        end

        return integer_change_stamps(ids) if all_int_ids

        key_list = Array.new(len)
        i = 0
        while i < len
          key_list[i] = "#{HLC::CHANGE_PREFIX}#{ids[i]}"
          i += 1
        end

        found = stamps(key_list)
        return {} if found.empty?

        result = {}
        i = 0
        while i < len
          if (stamp = found[key_list[i]])
            result[ids[i]] = stamp
          end
          i += 1
        end
        result
      end

      # Single-pass wire hash construction (omits sync_state, formats timestamps).
      # Always builds a fresh hash so frozen or shared custom attribute hashes
      # are never mutated.
      def wire_hash(attributes)
        out = {}
        attributes.each do |key, value|
          next if key == SYNC_STATE

          out[key] = value.respond_to?(:usec) ? value.iso8601(InstantRecord::TIME_PRECISION) : value
        end
        out
      end

      def plain_model?(model)
        model.instance_method(:attributes).owner == ActiveRecord::AttributeMethods &&
          model.instance_method(:_read_attribute).owner == ActiveRecord::AttributeMethods::Read &&
          model._initialize_callbacks.none? &&
          only_syncable_find_callbacks?(model)
      end

      def direct_relation?(records)
        alike?(records) &&
          records.preload_values.empty? && records.includes_values.empty? &&
          records.lock_value.nil? && !records.scheduled? &&
          !InstantRecord::SyncActions.enforcing_server_mutator? &&
          direct_plain_model?(records.model)
      end

      def direct_payloads(relation, result)
        model = relation.model
        sti_col = model.inheritance_column
        return nil if sti_col && !sti_col.empty? && result.includes_column?(sti_col)

        columns = result.columns
        col_len = columns.size
        col_index = {}
        i = 0
        while i < col_len
          col_index[columns[i]] = i
          i += 1
        end
        return nil if col_index.size != col_len

        pk = model.primary_key
        pk_idx = col_index[pk]
        return nil unless pk_idx

        model_types = model.attribute_types
        column_types = result.column_types
        unless column_types.empty?
          column_types = column_types.reject { |k, _| model_types.key?(k) }
        end

        raw_rows = result.rows
        first_raw = raw_rows[0]
        first_hash = {}
        i = 0
        while i < col_len
          first_hash[columns[i]] = first_raw[i]
          i += 1
        end

        # Probe row 0 through Active Record to discover exact attribute keys
        # and key order, and to honor any virtual/default attributes.
        first_record = model.send(:instantiate_instance_of, model, first_hash, column_types)
        first_attrs = first_record.attributes
        first_attrs.each_key do |name|
          return nil unless col_index.key?(name)
        end

        ver_idx = col_index[SERVER_VERSION]
        first_version = first_record[:server_version]
        return nil if ver_idx.nil? && !first_version.nil?

        dup_strings = model.connection_pool.with_connection(&:query_cache_enabled)

        names = []
        indices = []
        kinds = []
        types = []
        pk_kind = nil
        pk_type = nil
        ver_kind = nil
        ver_type = nil
        first_attrs.each_key do |name|
          next if name == SYNC_STATE

          idx = col_index[name]
          type = model_types.key?(name) ? model_types[name] : (column_types[name] || model_types[name])
          kind = classify_type(type, dup_strings)
          names << (-name)
          indices << idx
          kinds << kind
          types << type
          if name == pk
            pk_kind = kind
            pk_type = type
          end
          if name == SERVER_VERSION
            ver_kind = kind
            ver_type = type
          end
        end

        pk_in_attrs = !pk_kind.nil? && pk_kind <= KIND_INTEGER
        pk_key = -pk
        unless pk_in_attrs
          pk_type ||= model_types.key?(pk) ? model_types[pk] : (column_types[pk] || model_types[pk])
          pk_kind ||= classify_type(pk_type, dup_strings)
        end

        ver_in_attrs = !ver_idx.nil? && !ver_kind.nil? && ver_kind <= KIND_INTEGER
        if ver_idx && !ver_in_attrs
          ver_type ||= model_types.key?(SERVER_VERSION) ? model_types[SERVER_VERSION] : (column_types[SERVER_VERSION] || model_types[SERVER_VERSION])
          ver_kind ||= classify_type(ver_type, dup_strings)
        end

        type_name = model.name
        key_prefix = "#{HLC::RECORD_PREFIX}#{type_name}:"
        row_count = raw_rows.size
        payloads = Array.new(row_count)
        keys = Array.new(row_count)

        first_id = first_record.id
        keys[0] = "#{key_prefix}#{first_id}"
        payloads[0] = {
          type: type_name,
          id: first_id,
          version: first_version,
          attributes: wire_hash(first_attrs)
        }

        ncols = names.size
        r = 1
        while r < row_count
          raw = raw_rows[r]
          attrs = {}
          c = 0
          while c < ncols
            v = raw[indices[c]]
            kind = kinds[c]
            if kind == KIND_STRING
              v = types[c].deserialize(v) unless v.nil? || v.is_a?(String)
            elsif kind == KIND_INTEGER
              v = types[c].deserialize(v) unless v.nil? || v.is_a?(Integer)
            elsif kind == KIND_UTC_DATETIME
              if v.is_a?(String) && UTC_DATETIME_RE.match?(v)
                out = "#{v}Z"
                out.setbyte(10, 84)
                v = out
              elsif !v.nil?
                v = types[c].deserialize(v)
                v = v.iso8601(InstantRecord::TIME_PRECISION) if v.respond_to?(:usec)
              end
            elsif kind == KIND_STRING_DUP
              unless v.nil?
                v = v.is_a?(String) ? (v.frozen? ? v : String.new(v)) : types[c].deserialize(v)
              end
            else
              v = types[c].deserialize(v)
              v = v.iso8601(InstantRecord::TIME_PRECISION) if v.respond_to?(:usec)
            end
            attrs[names[c]] = v
            c += 1
          end

          id_val =
            if pk_in_attrs
              attrs[pk_key]
            else
              deserialize_scalar(raw[pk_idx], pk_kind, pk_type)
            end

          ver_val =
            if ver_in_attrs
              attrs[SERVER_VERSION]
            elsif ver_idx
              deserialize_scalar(raw[ver_idx], ver_kind, ver_type)
            end

          keys[r] = "#{key_prefix}#{id_val}"
          payloads[r] = {
            type: type_name,
            id: id_val,
            version: ver_val,
            attributes: attrs
          }
          r += 1
        end

        attach_stamps!(payloads, keys)
        payloads
      end

      def record_payloads_from_rows(rows, reader)
        len = rows.size
        payloads = Array.new(len)
        keys = Array.new(len)
        names_map = {}.compare_by_identity
        prefixes = {}.compare_by_identity

        i = 0
        while i < len
          record = rows[i]
          model = record.class
          type_name = names_map[model] ||= model.name
          prefix = prefixes[model] ||= "#{HLC::RECORD_PREFIX}#{type_name}:"
          id = record.id
          keys[i] = "#{prefix}#{id}"

          version = record[:server_version]
          attrs = reader ? reader.wire_attributes(record) : wire_hash(record.attributes)

          payloads[i] = {
            type: type_name,
            id: id,
            version: version,
            attributes: attrs
          }
          i += 1
        end

        attach_stamps!(payloads, keys)
        payloads
      end

      private

      def integer_change_stamps(ids)
        unique_ids = ids.size > 1 ? ids.uniq : ids
        total = unique_ids.size
        prefix = HLC::CHANGE_PREFIX
        prefix_len = prefix.bytesize
        in_sep = "','#{prefix}"
        result = {}
        SyncMetadata.connection_pool.with_connection do |conn|
          SyncMetadata.uncached do
            table = conn.quote_table_name(SyncMetadata.table_name)
            k_col = conn.quote_column_name("key")
            v_col = conn.quote_column_name("value")
            base_prefix = "SELECT #{k_col}, #{v_col} FROM #{table} WHERE #{k_col}"
            in_prefix = "#{base_prefix} IN ('#{prefix}"

            i = 0
            while i < total
              limit = i + SLICE
              limit = total if limit > total
              slice_len = limit - i
              sql =
                if slice_len == 1
                  "#{base_prefix} = '#{prefix}#{unique_ids[i]}'"
                else
                  slice = (i == 0 && limit == total) ? unique_ids : unique_ids[i, slice_len]
                  "#{in_prefix}#{slice.join(in_sep)}')"
                end

              rows = conn.select_rows(sql, "InstantRecord::SyncMetadata Pluck")
              r = 0
              rlen = rows.size
              while r < rlen
                pair = rows[r]
                val = pair[1]
                if val
                  k = pair[0]
                  klen = k.bytesize
                  pos = prefix_len
                  if klen > pos
                    num = 0
                    valid = true
                    while pos < klen
                      b = k.getbyte(pos)
                      if b >= 48 && b <= 57
                        num = num * 10 + (b - 48)
                        pos += 1
                      else
                        valid = false
                        break
                      end
                    end
                    result[num] = val if valid
                  end
                end
                r += 1
              end
              i = limit
            end
          end
        end
        result
      end

      def attach_stamps!(payloads, keys)
        found = stamps(keys)
        return if found.empty?

        i = 0
        len = payloads.size
        while i < len
          if (stamp = found[keys[i]])
            payloads[i][:hlc] = stamp
          end
          i += 1
        end
      end

      def only_syncable_find_callbacks?(model)
        cbs = model._find_callbacks
        return true if cbs.empty?
        return false unless model.respond_to?(:instant_record_syncable?) && model.instant_record_syncable?

        cbs.all? do |cb|
          cb.kind == :after && cb.filter.is_a?(Proc) && cb.filter.source_location&.first == SYNCABLE_FILE
        end
      end

      def plain_sql_string?(k)
        k.is_a?(String) &&
          (k.encoding == Encoding::UTF_8 || k.encoding == Encoding::US_ASCII) &&
          k.valid_encoding? &&
          !k.include?("'") && !k.include?("\\") && !k.include?("\0")
      end

      def plain_sql_strings?(slice)
        i = 0
        len = slice.size
        while i < len
          return false unless plain_sql_string?(slice[i])

          i += 1
        end
        true
      end

      def direct_plain_model?(model)
        plain_model?(model) &&
          model.instance_method(:read_attribute).owner == ActiveRecord::AttributeMethods::Read &&
          model.instance_method(:[]).owner == ActiveRecord::AttributeMethods &&
          model.instance_method(:id).owner == ActiveRecord::AttributeMethods::PrimaryKey &&
          model.instance_method(:init_with_attributes).owner == ActiveRecord::Core &&
          model.method(:attributes_builder).owner == ActiveRecord::ModelSchema::ClassMethods &&
          model.method(:instantiate_instance_of).owner == ActiveRecord::Persistence::ClassMethods &&
          model.method(:_load_from_sql).owner == ActiveRecord::Querying &&
          model.method(:_query_by_sql).owner == ActiveRecord::Querying &&
          model.primary_key.is_a?(String) &&
          !model.attribute_aliases.key?(SERVER_VERSION) &&
          !model.attribute_aliases.key?(model.primary_key)
      end

      def classify_type(type, dup_strings)
        if type.instance_of?(ActiveModel::Type::String) ||
           (defined?(ActiveRecord::Type::Text) && type.instance_of?(ActiveRecord::Type::Text))
          dup_strings ? KIND_STRING_DUP : KIND_STRING
        elsif type.instance_of?(ActiveModel::Type::Integer) ||
              type.instance_of?(ActiveModel::Type::BigInteger) ||
              (defined?(ActiveRecord::ConnectionAdapters::SQLite3Adapter::SQLite3Integer) &&
               type.instance_of?(ActiveRecord::ConnectionAdapters::SQLite3Adapter::SQLite3Integer))
          KIND_INTEGER
        elsif utc_datetime_type?(type)
          KIND_UTC_DATETIME
        else
          KIND_GENERIC
        end
      end

      def utc_datetime_type?(type)
        if type.instance_of?(ActiveRecord::Type::DateTime)
          type.is_utc? && (type.precision.nil? || type.precision >= InstantRecord::TIME_PRECISION)
        elsif type.instance_of?(ActiveModel::Type::DateTime)
          type.precision.nil? || type.precision >= InstantRecord::TIME_PRECISION
        elsif defined?(ActiveRecord::AttributeMethods::TimeZoneConversion::TimeZoneConverter) &&
              type.instance_of?(ActiveRecord::AttributeMethods::TimeZoneConversion::TimeZoneConverter)
          sub = type.__getobj__
          utc_sub =
            if sub.instance_of?(ActiveRecord::Type::DateTime)
              sub.is_utc? && (sub.precision.nil? || sub.precision >= InstantRecord::TIME_PRECISION)
            elsif sub.instance_of?(ActiveModel::Type::DateTime)
              sub.precision.nil? || sub.precision >= InstantRecord::TIME_PRECISION
            else
              false
            end
          return false unless utc_sub

          zone = Time.zone
          zone.nil? || zone.tzinfo&.canonical_identifier == "Etc/UTC"
        else
          false
        end
      end

      def deserialize_scalar(raw, kind, type)
        case kind
        when KIND_STRING
          raw.nil? || raw.is_a?(String) ? raw : type.deserialize(raw)
        when KIND_STRING_DUP
          raw.nil? ? nil : (raw.is_a?(String) ? (raw.frozen? ? raw : String.new(raw)) : type.deserialize(raw))
        when KIND_INTEGER
          raw.nil? || raw.is_a?(Integer) ? raw : type.deserialize(raw)
        else
          type.deserialize(raw)
        end
      end
    end
  end
end
