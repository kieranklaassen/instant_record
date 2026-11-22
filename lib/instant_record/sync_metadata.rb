module InstantRecord
  # Browser-local key/value store; holds the SSE cursor across reloads.
  class SyncMetadata < ActiveRecord::Base
    self.table_name = "instant_record_sync_metadata"
    self.primary_key = "key"

    def self.get(key)
      find_by(key: key)&.value
    end

    def self.set(key, value)
      if InstantRecord.browser?
        record = find_or_initialize_by(key: key)
        record.update!(value: value.to_s)
      else
        begin
          transaction(requires_new: true) do
            record = find_or_initialize_by(key: key)
            record.update!(value: value.to_s)
          end
        rescue ActiveRecord::RecordNotUnique
          where(key: key).update_all(value: value.to_s, updated_at: Time.now.utc)
        end
      end
    end

    def self.delete(key)
      where(key: key).delete_all
    end
  end
end
