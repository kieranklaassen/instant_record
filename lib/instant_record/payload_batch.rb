module InstantRecord
  class << self
    # record_payload for many records, with their clocks read together. The
    # same hashes, key for key. Server only, so it is kept out of
    # instant_record.rb, which the browser build compiles.
    def record_payloads(records)
      # Asked first: to_a loads the relation.
      reader = PayloadBatch::RowReader.new if PayloadBatch.alike?(records)
      rows = records.to_a
      keys = rows.map { |record| "#{HLC::RECORD_PREFIX}#{record.class.name}:#{record.id}" }
      stamps = PayloadBatch.stamps(keys)
      rows.zip(keys).map do |record, key|
        payload = {
          type: record.class.name,
          id: record.id,
          version: record[:server_version],
          attributes: wire_attributes(reader ? reader.attributes(record) : record.attributes)
        }
        if (stamp = stamps[key])
          payload[:hlc] = stamp
        end
        payload
      end
    end
  end

  # The clocks of a batch of rows, read a slice at a time rather than one by one.
  module PayloadBatch
    # Keys per query, under every supported database's bind limit.
    SLICE = 500

    # `record.attributes` for rows of one query. That call makes an object per
    # column to learn which columns a row has. Rows of one query and class have
    # the same, so it is asked of the first and the rest are read by name.
    class RowReader
      def initialize
        @names = {}.compare_by_identity
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

      private

      # A model that answers for its attributes itself is asked, row by row. So
      # is one whose callbacks see each row as it loads: they can leave a row
      # with other columns, or the same in another order. Syncable's own
      # after_find does neither. A model that overrides how Active Record makes
      # its rows is not looked for.
      def plain?(model)
        model.instance_method(:attributes).owner == ActiveRecord::AttributeMethods &&
          model.instance_method(:_read_attribute).owner == ActiveRecord::AttributeMethods::Read &&
          model._initialize_callbacks.none? && model._find_callbacks.one?
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

        SyncMetadata.connection_pool.with_connection do
          SyncMetadata.uncached do
            keys.uniq.each_slice(SLICE) do |slice|
              SyncMetadata.where(key: slice).pluck(:key, :value).each { |key, value| found[key] = value }
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
        keys = {}
        changes.each { |change| keys[change.id] = "#{HLC::CHANGE_PREFIX}#{change.id}" }
        found = stamps(keys.values)
        keys.transform_values! { |key| found[key] }.compact!
        keys
      end
    end
  end
end
