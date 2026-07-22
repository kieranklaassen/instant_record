module InstantRecord
  # Server-side ordered change log. The auto-increment id is the SSE cursor.
  class Change < ActiveRecord::Base
    self.table_name = "instant_record_changes"

    serialize :attributes_payload, coder: JSON

    scope :after, ->(cursor) { where("id > ?", cursor.to_i).order(:id) }

    # One poll of the change log for a streaming loop. Block-scoped connection
    # checkout — an idle stream must not pin a database connection while it
    # sleeps — and uncached, because the request executor's query cache would
    # otherwise return the first poll's result forever.
    def self.poll(cursor)
      connection_pool.with_connection do
        uncached { after(cursor).to_a }
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
