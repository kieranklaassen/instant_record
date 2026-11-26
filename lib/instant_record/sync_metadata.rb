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
        text = value.to_s
        # Only text SQLite compares as it was given takes the one statement.
        plain = [key.to_s, text].all? do |part|
          [Encoding::UTF_8, Encoding::US_ASCII].include?(part.encoding) && !part.include?("\0")
        end
        # SQLite leaves a transaction usable after a failed statement. Elsewhere
        # the savepoint does that for a caller that rescues the error.
        if plain && connection_pool.with_connection { |db| db.adapter_name.match?(/sqlite/i) }
          # One write, so a concurrent insert of the key is overwritten rather
          # than raised. Where the value is stored already it changes no row.
          now = Time.now.utc
          binds = { "key" => key, "value" => text, "created_at" => now, "updated_at" => now }.map do |column, given|
            ActiveRecord::Relation::QueryAttribute.new(column, given, type_for_attribute(column))
          end
          connection_pool.with_connection do |db|
            db.update(
              "INSERT INTO #{quoted_table_name} (\"key\", \"value\", \"created_at\", \"updated_at\") VALUES (?, ?, ?, ?) " \
              "ON CONFLICT (\"key\") DO UPDATE SET \"value\" = excluded.\"value\", \"updated_at\" = excluded.\"updated_at\" " \
              "WHERE \"value\" IS NOT excluded.\"value\"", "#{name} Upsert", binds
            )
          end
        else
          begin
            transaction(requires_new: true) do
              record = find_or_initialize_by(key: key)
              record.update!(value: text)
            end
          rescue ActiveRecord::RecordNotUnique
            where(key: key).update_all(value: text, updated_at: Time.now.utc)
          end
        end
        true
      end
    end

    def self.delete(key)
      where(key: key).delete_all
    end
  end
end
