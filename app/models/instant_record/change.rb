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
    # What a client with `scope` may hear of: its own changes and everyone's.
    scope :visible_to, ->(scope) { where(scope: [nil, scope.presence].uniq) }

    def self.poll(cursor, scope: nil)
      connection_pool.with_connection do
        uncached { after(cursor).visible_to(scope).to_a }
      end
    end

    def hlc
      InstantRecord::HLC.change_hlc(id)
    end

    def effective_hlc
      stamp = hlc
      return stamp if InstantRecord::HLC.valid?(stamp)

      InstantRecord::HLC.from_time(
        attributes_payload.is_a?(Hash) ? (attributes_payload["updated_at"] || created_at) : created_at,
        node: InstantRecord::HLC::SERVER_NODE
      )
    end

    def as_event
      event = {
        type: record_type,
        id: record_id,
        operation: operation,
        version: version,
        attributes: attributes_payload
      }
      if (stamp = hlc)
        event[:hlc] = stamp
      end
      event
    end
  end
end
