module InstantRecord
  class << self
    # record_payload for many records, with their clocks read together. The
    # same hashes, key for key. Server only, so it is kept out of
    # instant_record.rb, which the browser build compiles.
    def record_payloads(records)
      rows = records.to_a
      keys = rows.map { |record| "#{HLC::RECORD_PREFIX}#{record.class.name}:#{record.id}" }
      stamps = PayloadBatch.stamps(keys)
      rows.zip(keys).map do |record, key|
        payload = {
          type: record.class.name,
          id: record.id,
          version: record[:server_version],
          attributes: wire_attributes(record.attributes)
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

    class << self
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
