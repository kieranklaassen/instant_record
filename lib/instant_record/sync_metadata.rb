module InstantRecord
  # Browser-local key/value store; holds the SSE cursor across reloads.
  class SyncMetadata < ActiveRecord::Base
    self.table_name = "instant_record_sync_metadata"
    self.primary_key = "key"

    def self.get(key)
      find_by(key: key)&.value
    end

    def self.set(key, value)
      record = find_or_initialize_by(key: key)
      record.update!(value: value.to_s)
    end
  end
end
