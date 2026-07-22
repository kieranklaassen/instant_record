module InstantRecord
  class EventsController < ActionController::Base
    # SSE change stream as a lazily-enumerated response body — not
    # ActionController::Live (which burns a thread per stream and bypasses the
    # fiber scheduler; see docs/plans KTD1). An #each body is the portable
    # Rack streaming interface: Puma and Falcon both write each chunk as it
    # is yielded. Under Falcon each stream is a fiber, so `sleep` and pg
    # queries suspend the fiber; under Puma the body holds the request thread
    # (the pre-existing ceiling).
    #
    # The change-log row id is the event id, which doubles as the client's
    # cursor: catch-up from ?after= (or the Last-Event-ID reconnect header),
    # then tail for a bounded window and close — EventSource reconnects.
    EVENT_STREAM_HEADERS = {
      "content-type" => "text/event-stream",
      "cache-control" => "no-store",
      "x-accel-buffering" => "no",
      "access-control-allow-origin" => "*"
    }.freeze

    class EventStream
      def initialize(cursor:, deadline:)
        @cursor = cursor
        @deadline = deadline
      end

      def each
        loop do
          EventsController.fetch_changes(@cursor).each do |change|
            @cursor = change.id
            yield "id: #{change.id}\nevent: change\ndata: #{change.as_event.to_json}\n\n"
          end

          break if Time.current >= @deadline
          sleep 0.5
        end
      end
    end

    def index
      cursor = (request.headers["Last-Event-ID"] || params[:after] || 0).to_i
      deadline = Time.current + window_seconds

      headers.merge!(EVENT_STREAM_HEADERS)
      self.status = 200
      self.response_body = EventStream.new(cursor: cursor, deadline: deadline)
    end

    # Block-scoped connection checkout: an idle stream must not pin a database
    # connection while it sleeps (pool exhaustion is the ceiling after threads).
    # Uncached: the request executor enables the AR query cache, which would
    # return the first (empty) poll result for every later identical query.
    def self.fetch_changes(cursor)
      Change.connection_pool.with_connection do
        Change.uncached { Change.after(cursor).to_a }
      end
    end

    private

    def window_seconds
      ENV.fetch("INSTANT_RECORD_SSE_WINDOW", Rails.env.test? ? "0" : "25").to_f
    end
  end
end
