module InstantRecord
  class EventsController < ActionController::Base
    # SSE change stream as a lazily-enumerated response body — not
    # ActionController::Live (which burns a thread per stream and bypasses the
    # fiber scheduler). An #each body is the portable Rack streaming
    # interface: Puma and Falcon both write each chunk as it is yielded.
    # Under Falcon each stream is a fiber, so `sleep` and pg queries suspend
    # the fiber; under Puma the body holds the request thread.
    #
    # The change-log row id is the event id, which doubles as the client's
    # cursor: catch-up from ?after= (or the Last-Event-ID reconnect header),
    # then tail for a bounded window and close. ?window= lets a client shorten
    # the tail — the gem's own sync loop polls with window=0 (catch-up only)
    # so a tick never holds a long stream.
    EVENT_STREAM_HEADERS = {
      "content-type" => "text/event-stream",
      "cache-control" => "no-store",
      "x-accel-buffering" => "no"
    }.freeze

    class EventStream
      def initialize(cursor:, deadline:)
        @cursor = cursor
        @deadline = deadline
      end

      def each
        loop do
          Change.poll(@cursor).each do |change|
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

      headers.merge!(EVENT_STREAM_HEADERS).merge!(InstantRecord::CORS_HEADERS)
      self.response_body = EventStream.new(cursor: cursor, deadline: Time.current + window_seconds)
    end

    private

    def window_seconds
      configured = Rails.application.config.instant_record.sse_window_seconds.to_f
      requested = params[:window]&.to_f
      seconds = requested ? requested.clamp(0.0, configured) : configured

      # +/-10% jitter so a herd of streams opened together doesn't reconnect
      # in lockstep at every window boundary.
      seconds.positive? ? seconds * (0.9 + rand * 0.2) : seconds
    end
  end
end
