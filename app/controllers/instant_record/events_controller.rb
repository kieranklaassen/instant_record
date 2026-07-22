module InstantRecord
  class EventsController < ActionController::Base
    # SSE change stream as a Rack 3 streaming body (not ActionController::Live:
    # Live runs a child thread per stream, which holds a server thread and
    # bypasses the fiber scheduler — see docs/plans/...-003-...-plan.md KTD1).
    # Under Falcon each stream is a fiber and `sleep` yields; under Puma the
    # body holds the request thread, same ceiling as before.
    #
    # The change-log row id is the event id, which doubles as the client's
    # cursor: catch-up from ?after= (or the Last-Event-ID reconnect header),
    # then tail for a bounded window and close — EventSource reconnects.
    EVENT_STREAM_HEADERS = {
      "content-type" => "text/event-stream",
      "cache-control" => "no-cache",
      "x-accel-buffering" => "no",
      "access-control-allow-origin" => "*"
    }.freeze

    def index
      cursor = (request.headers["Last-Event-ID"] || params[:after] || 0).to_i
      deadline = Time.current + window_seconds

      body = proc do |stream|
        loop do
          self.class.fetch_changes(cursor).each do |change|
            cursor = change.id
            stream.write("id: #{change.id}\n")
            stream.write("event: change\n")
            stream.write("data: #{change.as_event.to_json}\n\n")
          end

          break if Time.current >= deadline
          sleep 0.5
        end
      rescue IOError, Errno::EPIPE
        # client went away; nothing to do
      ensure
        stream&.close
      end

      self.response = Rack::Response[200, EVENT_STREAM_HEADERS.dup, body]
    end

    # Block-scoped connection checkout: an idle stream must not pin a database
    # connection while it sleeps (pool exhaustion is the ceiling after threads).
    def self.fetch_changes(cursor)
      Change.connection_pool.with_connection do
        Change.after(cursor).to_a
      end
    end

    private

    def window_seconds
      ENV.fetch("INSTANT_RECORD_SSE_WINDOW", Rails.env.test? ? "0" : "25").to_f
    end
  end
end
