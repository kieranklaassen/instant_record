module InstantRecord
  # Server-side ordered change log. The auto-increment id is the SSE cursor.
  class Change < ActiveRecord::Base
    self.table_name = "instant_record_changes"

    serialize :attributes_payload, coder: JSON

    scope :after, ->(cursor) { where("id > ?", cursor.to_i).order(:id) }

    # What a client with `scope` may hear of: its own changes and everyone's.
    scope :visible_to, ->(scope) { where(scope: [nil, scope.presence].uniq) }

    # Partition filter: nil selects unpartitioned changes (partition IS NULL),
    # an empty array selects nothing, and a string or non-empty array selects
    # changes belonging to those partition keys.
    scope :in_partition, ->(partitions) do
      if partitions.nil?
        where(partition: nil)
      else
        list = Array(partitions).compact
        list.empty? ? none : where(partition: list)
      end
    end

    # One poll of the change log for a streaming loop. Block-scoped connection
    # checkout — an idle stream must not pin a database connection while it
    # sleeps — and uncached, because the request executor's query cache would
    # otherwise return the first poll's result forever.
    def self.poll(cursor, scope: nil, partition: nil)
      connection_pool.with_connection do
        uncached { after(cursor).in_partition(partition).visible_to(scope).to_a }
      end
    end

    def as_event
      {
        type: record_type,
        id: record_id,
        operation: operation,
        version: version,
        attributes: attributes_payload
      }
    end
  end
end
